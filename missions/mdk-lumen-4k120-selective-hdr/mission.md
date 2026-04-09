# Mission

MacDisplayKit를 Lumen이 SPM으로 소비할 수 있는 ScreenCaptureKit-유사 캡처/서빙 라이브러리로 완성한다. 목표는 4K HDR 이상 환경에서 120fps+ 캡처와 저지연 스트리밍을 지원하고, GPU 중심 zero-copy 파이프라인을 유지하며, macOS 네이티브 HDR 디스플레이처럼 필요한 영역만 자동 HDR로 송출하는 selective HDR 동작과 정확한 색공간 보존을 달성하는 것이다.

최적화 원칙:

- 몽키패치, 임시 우회, 측정 없는 추정 최적화는 금지한다.
- 전체 프레임 재처리를 전제로 한 미세 queue 튜닝보다, source/backend가 partial update와 HDR-active 영역 정보를 얼마나 보존하는지가 우선이다.
- 모든 실험은 `commit -> official metric -> keep/discard -> 자산화` 순서로 남긴다.
- 이미 버린 경로를 반복하지 않는다. 최근 `382-385`는 callback/mailbox handoff 재배치만으로는 keep를 넘지 못했고, current raw source cadence가 더 큰 ceiling이라는 점을 확인했다.
- `388`로 processor-local dirty-rect staging reuse도 닫혔다. reduced dirty rect를 encode processor까지 끌고 와서 직전 완료 슬롯에만 부분 BGRA→YUV 갱신을 해도 `HEVC` startup만 크게 악화됐고 progression은 그대로였다. 앞으로 dirty-rect 실험은 source-visible partial capture나 backend 수준에서만 고려한다.
- raw SkyLight target dirty-region probe에서도 같은 결론이 강화됐다. 현재 `3512x2290 x420` plain raw benchmark는 reduced dirty coverage가 평균 `~0.54`, rect count가 평균 `~3.4`, update drop은 `0`인데도 host 상태에 따라 raw cadence가 대략 `39-51 fps` 범위에 머문다. 즉 partial-update metadata는 존재하지만, source가 이미 full-surface 비용을 치른 뒤에야 내려오고 있다.
- target-sized private capture benchmark도 backend 우회 경로를 닫았다. `3512x2290`에서 direct `CGSHWCaptureDisplayIntoIOSurfaceWithOptions`는 SDR/HDR 모두 `~14.6-14.7 fps` 수준이고, proxy `SLSHWCaptureDisplayIntoIOSurfaceProxying`는 iteration은 돌지만 populated frame이 `0`이다. 현재 private backend selection은 정답이 아니다.
- `387`에서 `sdr_base_hdr_overlay`를 SDR `420v8` base stream + 분리된 overlay state 계약으로 옮겨봤지만, producer/probe가 overlay-active 신호를 독립적으로 못 세워서 공식 metric의 partial HDR이 0으로 무너졌다. 다음 selective HDR 구조 변경은 overlay-active truth source부터 먼저 세워야 한다.
- raw source attachment probe 결과, 현재 `SLDisplayStream`의 `x420`/`BGRA` 첫 프레임에는 `ColorPrimaries`, `TransferFunction`, `MasteringDisplayColorVolume`, `ContentLightLevelInfo`가 아예 안 붙는다. `420v`는 SDR `ITU_R_709_2`만 붙는다. 즉 selective HDR을 encoded sample metadata에서 복원하려는 방향은 근본적으로 불리하고, source/backend가 따로 제공하는 overlay-active truth를 찾아야 한다.
