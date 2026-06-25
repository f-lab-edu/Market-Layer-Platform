# serving (전달 계층)

> 생명주기 기준 분할의 **serving** 계층 — "사용자에게 결과를 전달하는" 워크로드가 들어간다.
> 네임스페이스: `serving`. **Week 1~2 현재 비어 있는 게 정상**(Week 3부터 채워짐).

## 무엇이 들어가나 (Week 3~)

- 추론 API (FastAPI) — 이벤트/거시 분류 결과 제공
- brief 생성 로직 (RAG + LLM, 출력 검증)
- 텔레그램 봇 (매일 아침 브리프 발송)

## 동작 방식

`pipeline`이 만든 Gold feature/모델을 읽어 추론하고, 결과(브리프)를 사용자에게 outbound로 전달한다. 외부 노출이 필요해지면 ingress-nginx(NodePort)로 연결.
