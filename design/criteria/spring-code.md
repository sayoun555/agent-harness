# 코드 기준 — Spring (초안)

> Spring Boot 프로젝트의 코드 기준이다. 객체지향 기준(oop-code.md)과 함께 쓴다.

## K9. 설정은 타입 있는 객체로 한곳에서

- **규칙:**
  - 관련 설정은 `@ConfigurationProperties` 로 묶어 `record` 로 받는다. 여기저기 흩어진 `@Value` 를 쓰지 않는다.
  - `@Validated` 와 제약(`@NotBlank`, `@Positive` 등)으로 **시작할 때** 검증한다. 잘못된 설정으로 뜬 뒤 런타임에 터지게 두지 않는다.
  - 환경별 값은 프로필(`application-{profile}.yml`)로 나누고, 비밀은 `${이름}` 참조만 둔다 (B8).
  - 기능 켜기·끄기는 설정 값과 `@ConditionalOnProperty` 로 한다. 코드의 `if (env == prod)` 로 하지 않는다.
  - 매직 넘버·URL·시간 제한은 이름 있는 상수나 설정으로 뺀다.
- **이유:** 흩어진 설정은 무엇이 필요한지 알 수 없고, 오타가 운영에서야 드러난다.
- **적용 조건:** Spring Boot. 설정 값이 하나뿐인 작은 모듈은 `record` 로 묶지 않아도 된다.
- **확인 방법:** check 게이트의 하드코딩 URL·호스트 경고. 검증자가 새 `@Value`, 시작 시 검증 없는 설정, 코드 안 환경 분기를 지적한다.
