# PocketIMG Spec Coding

沿用 MotoKey 的规格组织方式：每项需求包含 `spec.md`（行为与验收）、`plan.md`（实现方案与顺序）、`tasks.md`（可追踪任务）。先核对代码基线，再明确行为，最后实现和验证。

规格中的建议不代表已实现；只有相应验证完成后才能勾选任务。规格发生变化时同步修改计划和任务。

| 编号 | 主题 | 状态 |
| --- | --- | --- |
| 001 | 后端安装自动生成并展示 Token | 已实现；Docker 与 Linux systemd 实机验收通过 |
| 002 | 图床与 Mac 产品文案和展示素材 | 首版完成；Web 实拍与 Mac 流程示意已校验 |

入口：[Spec 001](001-backend-token-bootstrap/spec.md) · [Plan](001-backend-token-bootstrap/plan.md) · [Tasks](001-backend-token-bootstrap/tasks.md)

产品展示：[Spec 002](002-product-story/spec.md) · [Plan](002-product-story/plan.md) · [Tasks](002-product-story/tasks.md)
