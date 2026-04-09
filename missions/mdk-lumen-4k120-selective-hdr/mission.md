# Mission

MacDisplayKit를 Lumen이 SPM으로 소비할 수 있는 ScreenCaptureKit-유사 캡처/서빙 라이브러리로 완성한다. 목표는 4K HDR 이상 환경에서 120fps+ 캡처와 저지연 스트리밍을 지원하고, GPU 중심 zero-copy 파이프라인을 유지하며, macOS 네이티브 HDR 디스플레이처럼 필요한 영역만 자동 HDR로 송출하는 selective HDR 동작과 정확한 색공간 보존을 달성하는 것이다.

최적화 원칙:

- 몽키패치, 임시 우회, 측정 없는 추정 최적화는 금지한다.
- 전체 프레임 재처리를 전제로 한 미세 queue 튜닝보다, source/backend가 partial update와 HDR-active 영역 정보를 얼마나 보존하는지가 우선이다.
- 모든 실험은 `commit -> official metric -> keep/discard -> 자산화` 순서로 남긴다.
- 이미 버린 경로를 반복하지 않는다. 최근 `382-385`는 callback/mailbox handoff 재배치만으로는 keep를 넘지 못했고, current raw source cadence가 더 큰 ceiling이라는 점을 확인했다.
