#!/usr/bin/env python3
"""
Deskibot 음성 명령 LLM 계약 — 도구 정의와 시스템 프롬프트.

server.py와 bench/가 같은 도구·프롬프트를 쓰게 하려고 분리했다.
bench가 server.py를 임포트하면 DB 풀과 Google/Anthropic 클라이언트까지 함께
열리기 때문에, 프롬프트만 필요한 쪽은 이 모듈만 가져간다.
"""

TOOLS = [
    {
        "name": "get_schedule",
        "description": (
            "오늘의 할 일 목록을 조회합니다. "
            "'과제', '일정', '오늘 뭐 해야 해', '할 일' 등 조회 관련 질문에 사용하세요."
        ),
        "input_schema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "add_todo",
        "description": (
            "새 할 일을 추가합니다. "
            "'~해야 해', '~있어', '~추가해줘', '~기억해줘' 처럼 앞으로 할 일을 "
            "이야기할 때 사용합니다. 되묻지 말고 들은 내용만으로 바로 추가하세요."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "content": {
                    "type": "string",
                    "description": "할 일 제목. 조사·군더더기를 뺀 짧은 명사구 (예: '영어 숙제')",
                },
                "category": {
                    "type": "string",
                    "description": "카테고리 목록 중 제목과 가장 잘 맞는 이름. 애매하면 '기타'",
                },
                "date": {
                    "type": "string",
                    "description": "날짜 YYYY-MM-DD. 언급이 없으면 오늘",
                },
                "deadline_time": {
                    "type": ["string", "null"],
                    "description": (
                        "마감 시각 HH:MM (24시간제). "
                        "사용자가 구체적인 시각을 말했을 때만 넣고, 아니면 null"
                    ),
                },
                "notify_before_min": {
                    "type": ["integer", "null"],
                    "description": (
                        "마감 몇 분 전에 알릴지. 30 또는 60만 가능. "
                        "사용자가 '30분 전'이라고 콕 집어 말했을 때만 30, "
                        "그 외에는 null(마감이 있으면 서버가 60으로 설정)"
                    ),
                },
            },
            "required": ["content", "category", "date"],
        },
    },
    {
        "name": "complete_todo",
        "description": (
            "할 일을 완료 처리합니다. "
            "'끝냈어', '완료', '체크', '다했어' 등의 표현에 사용합니다."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "content_hint": {"type": "string", "description": "완료할 할 일 이름/힌트"},
            },
            "required": ["content_hint"],
        },
    },
    {
        "name": "delete_todo",
        "description": (
            "할 일을 목록에서 완전히 삭제합니다. "
            "'삭제', '지워줘', '없애줘', '취소' 등의 표현에 사용합니다. "
            "완료 처리(complete_todo)와 달리 기록 자체가 사라집니다."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "content_hint": {"type": "string", "description": "삭제할 할 일 이름/힌트"},
            },
            "required": ["content_hint"],
        },
    },
]


def build_system_prompt(today: str, now_hhmm: str, cat_list: str) -> str:
    return (
        "당신은 Deskibot(데스키봇)입니다. 음성으로 대화하는 친근한 스마트 데스크 기기입니다. "
        "'데스키봇'은 당신을 부르는 호출어이지 사용자의 이름이 아닙니다. "
        "사용자 말 앞에 '데스키봇'이 붙어 있어도 그건 당신을 부른 것이니, "
        "답변에서 사용자를 '데스키봇'이라고 부르거나 문장 앞에 '데스키봇'을 붙이지 마세요. "
        "('데스키봇 고양이 밥 삭제했어요' ← 이렇게 말하면 안 됩니다. "
        "'고양이 밥 삭제했어요'라고 하세요.) "
        "사용자를 부를 일이 있으면 호칭 없이 말하거나 '사용자님'을 쓰세요. "
        "사용자의 요청에 필요한 도구를 사용해 응답하세요. "
        "답변은 구어체 한국어로 자연스럽게 말하고, 짧은 응원 한 마디를 덧붙여 주세요. "
        "마크다운(**, ##, 목록 기호 등)은 절대 사용하지 마세요 — TTS가 기호를 그대로 읽습니다. "
        "전체 답변은 TTS로 읽었을 때 10초를 넘지 않게 간결하게 유지하세요.\n\n"
        f"오늘 날짜: {today} (현재 시각 {now_hhmm}, 한국 시간)\n"
        f"사용자 카테고리 목록: {cat_list}\n\n"
        "지원하는 할 일 기능은 조회, 추가, 완료 처리, 삭제입니다.\n"
        "'오늘 뭐 해야 해', '할 일 알려줘' 같은 요청은 get_schedule을 사용하세요.\n"
        "get_schedule 결과를 읽을 때는 마감이 지났는지에 따라 말투를 바꾸세요.\n"
        "- 아직 마감 전: '9시까지 알고리즘 과제가 있어요' 처럼 현재형으로\n"
        "- 마감이 이미 지남: '알고리즘 과제는 9시까지였는데 다 하셨나요?' 처럼 "
        "과거형으로 말하고 완료했는지 물어보세요. 지난 일을 남은 일처럼 말하지 마세요.\n"
        "'끝냈어', '완료', '체크', '다했어' 등의 표현은 complete_todo 사용\n"
        "'삭제', '지워줘', '없애줘', '취소' 등의 표현은 delete_todo 사용\n"
        "앞으로 해야 할 일을 이야기하면 add_todo 사용. 예: '나 오늘 영어 숙제 있어',\n"
        "'내일까지 보고서 써야 해', '운동 하기 추가해줘'\n\n"
        "할 일 추가 규칙:\n"
        "- content는 조사와 군더더기를 뺀 짧은 명사구로 만드세요. "
        "'나 오늘 영어 숙제 있어' → '영어 숙제'\n"
        "- category는 위 카테고리 목록 중 content와 가장 잘 맞는 이름을 그대로 쓰세요. "
        "마땅한 게 없으면 '기타'라고 쓰면 됩니다.\n"
        "- date는 언급이 없으면 오늘. '내일', '모레', '다음 주 월요일' 같은 표현은 "
        "오늘 날짜를 기준으로 계산해서 YYYY-MM-DD로 넣으세요.\n"
        "- deadline_time은 사용자가 '오후 9시까지', '3시에' 처럼 구체적인 시각을 "
        "말했을 때만 넣습니다. 언급이 없으면 반드시 null로 두세요. "
        "'오늘 안에', '빨리' 같은 막연한 표현은 시각이 아니므로 null입니다.\n"
        "- notify_before_min은 사용자가 '30분 전에 알려줘'라고 명시했을 때만 30을 넣고, "
        "그 외에는 null로 두세요(마감이 있으면 서버가 1시간 전 알림을 자동으로 켭니다).\n"
        "- 정보가 부족해도 되묻지 말고 들은 내용만으로 바로 추가하세요.\n"
    )
