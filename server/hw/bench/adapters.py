#!/usr/bin/env python3
"""
STT 엔진 어댑터. 모두 같은 인터페이스를 지킨다:

    transcribe(pcm: bytes, use_hints: bool) -> (text, latency_sec)

pcm은 서버가 ESP32에서 받는 것과 같은 16 kHz / 16-bit / mono little-endian.
같은 바이트를 세 엔진에 그대로 먹여야 비교가 성립한다.
"""

import io, os, time, wave
import requests

SAMPLE_RATE = 16000

# server.py의 STT_PHRASE_HINTS와 같은 목록을 쓴다. 여기서 갈리면 비교가 무의미하다.
PHRASE_HINTS = [
    "데스키봇",
    "뽀모도로", "집중", "타이머", "스톱워치",
    "할 일", "일정", "마감", "알림",
    "추가", "삭제", "완료",
]
PHRASE_BOOST = 15.0


def pcm_to_wav(pcm: bytes) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm)
    return buf.getvalue()


class Adapter:
    name = "base"
    supports_hints = False

    def transcribe(self, pcm: bytes, use_hints: bool = False):
        raise NotImplementedError


# ─── Google Cloud Speech v1 (현행 운영 구성) ──────────────────────────────────
class GoogleV1(Adapter):
    name = "google_v1"
    supports_hints = True

    def __init__(self):
        from google.cloud import speech
        from google.api_core.client_options import ClientOptions
        self._speech = speech
        self._client = speech.SpeechClient(
            client_options=ClientOptions(api_key=os.environ["GOOGLE_API_KEY"])
        )

    def transcribe(self, pcm: bytes, use_hints: bool = False):
        speech = self._speech
        contexts = (
            [speech.SpeechContext(phrases=PHRASE_HINTS, boost=PHRASE_BOOST)]
            if use_hints else []
        )
        config = speech.RecognitionConfig(
            encoding=speech.RecognitionConfig.AudioEncoding.LINEAR16,
            sample_rate_hertz=SAMPLE_RATE,
            language_code="ko-KR",
            enable_automatic_punctuation=True,
            speech_contexts=contexts,
        )
        t0 = time.time()
        resp = self._client.recognize(
            config=config, audio=speech.RecognitionAudio(content=pcm)
        )
        text = "".join(r.alternatives[0].transcript for r in resp.results)
        return text, time.time() - t0


# ─── Google Cloud Speech v2 (chirp_2) ────────────────────────────────────────
class GoogleV2(Adapter):
    """
    v2는 API 키가 아니라 ADC(서비스 계정) 인증이 필요하다.
    GOOGLE_APPLICATION_CREDENTIALS와 GCP_PROJECT_ID를 설정해야 동작한다.
    chirp_2는 리전이 제한되므로 GCP_STT_LOCATION으로 조정한다.
    """
    name = "google_v2"
    supports_hints = False   # chirp_2는 v1식 speech_contexts를 받지 않는다

    def __init__(self):
        from google.cloud.speech_v2 import SpeechClient
        from google.cloud.speech_v2.types import cloud_speech
        from google.api_core.client_options import ClientOptions
        self._types = cloud_speech
        self._project = os.environ["GCP_PROJECT_ID"]
        self._location = os.environ.get("GCP_STT_LOCATION", "us-central1")
        self._model = os.environ.get("GCP_STT_MODEL", "chirp_2")
        self._client = SpeechClient(
            client_options=ClientOptions(
                api_endpoint=f"{self._location}-speech.googleapis.com"
            )
        )

    def transcribe(self, pcm: bytes, use_hints: bool = False):
        t = self._types
        config = t.RecognitionConfig(
            explicit_decoding_config=t.ExplicitDecodingConfig(
                encoding=t.ExplicitDecodingConfig.AudioEncoding.LINEAR16,
                sample_rate_hertz=SAMPLE_RATE,
                audio_channel_count=1,
            ),
            language_codes=["ko-KR"],
            model=self._model,
        )
        req = t.RecognizeRequest(
            recognizer=f"projects/{self._project}/locations/{self._location}/recognizers/_",
            config=config,
            content=pcm,
        )
        t0 = time.time()
        resp = self._client.recognize(request=req)
        text = "".join(r.alternatives[0].transcript for r in resp.results if r.alternatives)
        return text, time.time() - t0


# ─── CLOVA Speech Recognition (CSR, 단문) ────────────────────────────────────
class ClovaCSR(Adapter):
    """
    NCP API Gateway 인증(client id + api key). .env의 NAVER_CLLIENT_ID 오타를
    그대로 두어도 되도록 두 철자를 모두 본다.

    CSR에는 키워드 부스팅이 없다. Google의 phrase hints에 대응하는 기능은
    Clova Speech(장문 API) 쪽에만 있으므로, 공정 비교의 기준선은 '힌트 없음'이다.
    """
    name = "clova_csr"
    supports_hints = False

    ENDPOINT = os.environ.get(
        "CLOVA_CSR_URL", "https://naveropenapi.apigw.ntruss.com/recog/v1/stt"
    )

    def __init__(self):
        self._client_id = (
            os.environ.get("NAVER_CLIENT_ID") or os.environ.get("NAVER_CLLIENT_ID", "")
        )
        self._api_key = os.environ.get("NAVER_API_KEY", "")
        if not self._client_id or not self._api_key:
            raise RuntimeError("NAVER_CLIENT_ID(또는 NAVER_CLLIENT_ID)와 NAVER_API_KEY 필요")

    def transcribe(self, pcm: bytes, use_hints: bool = False):
        headers = {
            "X-NCP-APIGW-API-KEY-ID": self._client_id,
            "X-NCP-APIGW-API-KEY": self._api_key,
            "Content-Type": "application/octet-stream",
        }
        t0 = time.time()
        r = requests.post(
            self.ENDPOINT, params={"lang": "Kor"}, headers=headers,
            data=pcm_to_wav(pcm), timeout=30,
        )
        dt = time.time() - t0
        r.raise_for_status()
        return r.json().get("text", ""), dt


# ─── CLOVA Speech (장문, 키워드 부스팅 지원) ─────────────────────────────────
class ClovaSpeech(Adapter):
    """
    별도 구독이 필요하다. CLOVA_SPEECH_INVOKE_URL과 CLOVA_SPEECH_SECRET이
    있을 때만 후보에 올라간다. 이쪽만 Google phrase hints와 대등한 비교가 된다.
    """
    name = "clova_speech"
    supports_hints = True

    def __init__(self):
        self._url = os.environ["CLOVA_SPEECH_INVOKE_URL"].rstrip("/")
        self._secret = os.environ["CLOVA_SPEECH_SECRET"]

    def transcribe(self, pcm: bytes, use_hints: bool = False):
        import json as _json
        params = {"language": "ko-KR", "completion": "sync"}
        if use_hints:
            params["boostings"] = [{"words": " ".join(PHRASE_HINTS)}]
        files = {
            "media": ("audio.wav", pcm_to_wav(pcm), "application/octet-stream"),
            "params": (None, _json.dumps(params, ensure_ascii=False), "application/json"),
        }
        t0 = time.time()
        r = requests.post(
            f"{self._url}/recognizer/upload",
            headers={"X-CLOVASPEECH-API-KEY": self._secret},
            files=files, timeout=60,
        )
        dt = time.time() - t0
        r.raise_for_status()
        return r.json().get("text", ""), dt


REGISTRY = {
    "google_v1":    GoogleV1,
    "google_v2":    GoogleV2,
    "clova_csr":    ClovaCSR,
    "clova_speech": ClovaSpeech,
}


def build(names):
    """생성 가능한 어댑터만 돌려준다. 자격증명이 없는 엔진은 건너뛰고 이유를 알린다."""
    out = []
    for n in names:
        try:
            out.append(REGISTRY[n]())
            print(f"[bench] ✅ {n} 준비됨")
        except Exception as e:
            print(f"[bench] ⏭  {n} 건너뜀: {e}")
    return out
