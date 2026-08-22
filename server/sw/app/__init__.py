"""sw API 서버 애플리케이션 패키지.

server/common/ 을 import 할 수 있게 부모 디렉터리(server/)를 경로에 넣는다.
common 은 hw 와 sw 가 함께 쓰는 모듈이라 두 앱의 바깥에 있는데, 그대로는
`from common.db import ...` 가 해석되지 않는다.

PYTHONPATH 를 systemd 유닛에만 넣으면 로컬에서 테스트를 돌릴 때 ImportError 가
난다. 여기서 잡으면 실행 위치·실행 방식과 무관하게 항상 같은 모듈을 본다.
"""

import sys
from pathlib import Path

_SERVER_DIR = Path(__file__).resolve().parent.parent.parent
if str(_SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(_SERVER_DIR))
