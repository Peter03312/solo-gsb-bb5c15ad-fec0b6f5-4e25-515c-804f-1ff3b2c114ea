"""证据撤回承受力分析（只读）。

考古人员核对当前地层关系时，需要知道它对**证据撤回**的承受力：在不改变任何
断言、修订与变化记录的前提下，求使两个已登记地层的关系变为未定，所需撤回的
最少**生效证据**数，以及撤回数并列时证据编号序列字典序最小的一组。

口径（与推导引擎一致）：

- 同一期证据是无向边：撤回一条即双向连通同时断开，按一条证据计数；
- 早于证据是 a→b 的有向边；沿“同一期 + 早于”混合路径推导关系；
- 最小割（受保护证据容量为无穷大）即最少撤回数——替代证据路径仍成立时
  目标不会判为失效；
- 存在完全由受保护证据构成的路径时目标不可失效（`reachable=false`），
  返回“仅保留受保护证据”视图下仍成立的关系与最优证据路径；
- 原关系未定时返回 0 与空集合。

视图在 `REPEATABLE READ READ ONLY` 快照事务内读取，修订号在事务内只读一次：
过期返回 409 STALE_REVISION，不输出混合版本。结构性拒绝：地层未登记
（400 INVALID_STRATUM）、两个地层相同（400 DUPLICATE_STRATUM）、受保护证据
不存在或非生效（400 INVALID_PROTECTED_EVIDENCE）。既有接口语义不变。
"""
from __future__ import annotations

from typing import Any, Dict, List, Optional

from .db import db_conn
from .derivation import Assertion, RELATION_LABELS, WithdrawalAnalysis, withdrawal_analysis
from .errors import ApiError
from .models import WithdrawalAnalysisIn


def _label(relation: str) -> str:
    return RELATION_LABELS[relation]


def _path_details(cur, path: Optional[List[str]]) -> List[Dict[str, Any]]:
    """把证据编号序列展开为按序的原始断言（结构同关系查询 path_detail）。"""
    if not path:
        return []
    cur.execute(
        "SELECT evidence_id, stratum_a, stratum_b, relation, status "
        "FROM assertions WHERE evidence_id = ANY(%s)",
        (list(path),),
    )
    rows = {r[0]: r for r in cur.fetchall()}
    return [
        {
            "evidence_id": eid,
            "stratum_a": rows[eid][1],
            "stratum_b": rows[eid][2],
            "relation": rows[eid][3],
            "status": rows[eid][4],
        }
        for eid in path
        if eid in rows
    ]


def analyze(body: WithdrawalAnalysisIn) -> Dict[str, Any]:
    """只读分析：返回两层关系对证据撤回的承受力。不写库、不递增修订号。"""
    raw_protected = list(body.protected_evidence or [])
    protected_ids = sorted(set(raw_protected))

    with db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SET TRANSACTION READ ONLY ISOLATION LEVEL REPEATABLE READ")

            cur.execute("SELECT revision FROM revision_counter WHERE id = TRUE")
            current = cur.fetchone()[0]
            if body.expected_revision != current:
                raise ApiError(
                    409,
                    "STALE_REVISION",
                    f"修订号过期：请求携带 {body.expected_revision}，当前正式修订号为 {current}",
                    {"current_revision": current, "scope": "formal"},
                )

            cur.execute("SELECT stratum_id FROM strata WHERE stratum_id = ANY(%s)", ([body.stratum_a, body.stratum_b],))
            known = {r[0] for r in cur.fetchall()}
            for s in (body.stratum_a, body.stratum_b):
                if s not in known:
                    raise ApiError(
                        400, "INVALID_STRATUM", f"地层未登记: {s}", {"stratum_id": s}
                    )
            if body.stratum_a == body.stratum_b:
                raise ApiError(
                    400,
                    "DUPLICATE_STRATUM",
                    f"两个地层必须不同：{body.stratum_a}",
                    {"stratum_id": body.stratum_a},
                )

            cur.execute(
                "SELECT evidence_id, status FROM assertions WHERE evidence_id = ANY(%s)",
                (protected_ids,),
            )
            prot_rows = {r[0]: r[1] for r in cur.fetchall()}
            not_found = [eid for eid in protected_ids if eid not in prot_rows]
            not_active = [eid for eid in protected_ids if prot_rows.get(eid) == "retracted"]
            if not_found or not_active:
                details: Dict[str, Any] = {}
                if not_found:
                    details["evidence_not_found"] = not_found
                if not_active:
                    details["evidence_not_active"] = not_active
                raise ApiError(
                    400,
                    "INVALID_PROTECTED_EVIDENCE",
                    "受保护证据无效：须为当前视图中存在且生效的证据编号",
                    details,
                )

            cur.execute(
                "SELECT evidence_id, stratum_a, stratum_b, relation "
                "FROM assertions WHERE status = 'active' ORDER BY evidence_id"
            )
            assertions = [
                Assertion(evidence_id=r[0], a=r[1], b=r[2], relation=r[3]) for r in cur.fetchall()
            ]

            result: WithdrawalAnalysis = withdrawal_analysis(
                assertions, body.stratum_a, body.stratum_b, frozenset(protected_ids)
            )

            suggested = list(result.suggested_retractions)
            original_path = list(result.original_path) if result.original_path is not None else None
            simulated_path = list(result.simulated_path) if result.simulated_path is not None else None

            payload: Dict[str, Any] = {
                "scope": "formal",
                "expected_revision": body.expected_revision,
                "current_revision": current,
                "revision": current,
                "stratum_a": body.stratum_a,
                "stratum_b": body.stratum_b,
                "protected_evidence": protected_ids,
                "protected_evidence_count": len(protected_ids),
                "original_relation": result.original_relation,
                "original_relation_label": _label(result.original_relation),
                "original_evidence_path": original_path,
                "original_path_detail": _path_details(cur, original_path),
                "reachable": result.reachable,
                "simulated_relation": result.simulated_relation,
                "simulated_relation_label": _label(result.simulated_relation),
                "simulated_evidence_path": simulated_path,
                "simulated_path_detail": _path_details(cur, simulated_path),
                "suggested_retractions": [],
                "retraction_count": 0,
            }

            if not result.determined:
                # 原关系本就未定：零撤回、空集合
                payload["status"] = "already_undetermined"
                payload["message"] = "原关系已为未定，无需撤回任何证据"
                return payload

            if not result.reachable:
                # 受保护证据保证一条推导路径始终成立：目标不可失效
                payload["status"] = "protected_unreachable"
                payload["retraction_count"] = None
                payload["message"] = (
                    "目标不可达：受保护生效证据保证至少一条证据路径始终成立，"
                    "撤回其余任何生效证据都无法使该关系变为未定；"
                    "simulated_* 为仅保留受保护证据后仍成立的关系与证据路径"
                )
                payload["surviving_evidence_path"] = simulated_path
                payload["surviving_path_detail"] = payload["simulated_path_detail"]
                return payload

            payload["status"] = "retractions_found"
            payload["retraction_count"] = result.minimum
            payload["suggested_retractions"] = suggested
            payload["message"] = (
                f"撤回 {result.minimum} 条生效证据（字典序最小方案）后，"
                f"{body.stratum_a} 与 {body.stratum_b} 的关系变为未定"
            )
            return payload
