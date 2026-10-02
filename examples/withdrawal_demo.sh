#!/usr/bin/env bash
# 考古地层关系核验服务 —— 证据撤回承受力分析（POST /relationship/withdrawal-analysis）示例
#
# 分析只读：不修改断言、修订或变化记录，不递增修订号。
# 给定预期正式修订号、两个已登记地层与可为空的受保护生效证据编号集合，
# 求使两层关系变为未定所需撤回的最少生效证据（只能从其余生效证据中选取），
# 并列取证据编号序列字典序最小的一组；返回原关系、原最优证据路径、
# 建议撤回编号与模拟撤回后的关系。同一期双向连通按一条证据计数；
# 替代证据路径仍成立时不判失效；受保护证据使目标无法失效时明确返回不可达
# 及仍成立的证据路径；原关系未定时返回零与空集合。
#
# 前提：服务已启动（docker compose up --build），监听 http://localhost:8000
set -euo pipefail

BASE="${BASE_URL:-http://localhost:8000}"
pp() { python3 -m json.tool 2>/dev/null || cat; }

echo "== 0. 登记本示例专用地层 =="
for s in W1 W2 W3 W4; do
  curl -s -X POST "$BASE/strata" -H 'Content-Type: application/json' \
    -d "{\"stratum_id\": \"$s\", \"site\": \"撤回承受力演示区\"}" | pp >/dev/null || true
done

echo; echo "== 1. 建立正式视图（仅在修订号为 0 时初始化）："
echo "   W1~W2 同一期(WV-1)，W2<W3(WV-2)，W1<W3 直达(WV-3)，W3<W4(WV-4)"
REV="$(curl -s "$BASE/revision" | python3 -c 'import sys,json;print(json.load(sys.stdin)["revision"])')"
if [ "$REV" = 0 ]; then
  curl -s -X POST "$BASE/batches" -H 'Content-Type: application/json' -d '{
    "expected_revision": 0,
    "operations": [
      {"op": "assert", "evidence_id": "WV-1", "stratum_a": "W1", "stratum_b": "W2", "relation": "same_period"},
      {"op": "assert", "evidence_id": "WV-2", "stratum_a": "W2", "stratum_b": "W3", "relation": "earlier_than"},
      {"op": "assert", "evidence_id": "WV-3", "stratum_a": "W1", "stratum_b": "W3", "relation": "earlier_than"},
      {"op": "assert", "evidence_id": "WV-4", "stratum_a": "W3", "stratum_b": "W4", "relation": "earlier_than"}
    ]}' | pp
fi
REV="$(curl -s "$BASE/revision" | python3 -c 'import sys,json;print(json.load(sys.stdin)["revision"])')"
echo "（当前修订号 $REV）"

echo; echo "== 2. W1 与 W3：双路径（WV-3 直达；WV-1+WV-2 经 W2），撤回一条仍有替代路径"
echo "   -> retractions_found，最少 2 条；字典序最小 [WV-1, WV-3]，模拟后 undetermined =="
curl -s -X POST "$BASE/relationship/withdrawal-analysis" -H 'Content-Type: application/json' -d "{
  \"expected_revision\": $REV,
  \"stratum_a\": \"W1\",
  \"stratum_b\": \"W3\",
  \"protected_evidence\": []
}" | pp

echo; echo "== 3. 反向查询 W3 与 W1（原关系为晚于 later_than），撤回集合相同 =="
curl -s -X POST "$BASE/relationship/withdrawal-analysis" -H 'Content-Type: application/json' -d "{
  \"expected_revision\": $REV,
  \"stratum_a\": \"W3\",
  \"stratum_b\": \"W1\"
}" | pp

echo; echo "== 4. W1 与 W4：链上瓶颈是 W3<W4（WV-4）；最少 1 条即 [WV-4] =="
curl -s -X POST "$BASE/relationship/withdrawal-analysis" -H 'Content-Type: application/json' -d "{
  \"expected_revision\": $REV,
  \"stratum_a\": \"W1\",
  \"stratum_b\": \"W4\"
}" | pp

echo; echo "== 5. 原关系未定：另登记孤立地层 W9，W1 与 W9 之间无任何推导路径"
echo "   -> already_undetermined：retraction_count=0、suggested_retractions=[] =="
curl -s -X POST "$BASE/strata" -H 'Content-Type: application/json' \
    -d '{"stratum_id": "W9", "site": "撤回承受力演示区"}' | pp >/dev/null || true
curl -s -X POST "$BASE/relationship/withdrawal-analysis" -H 'Content-Type: application/json' -d "{
  \"expected_revision\": $REV,
  \"stratum_a\": \"W1\",
  \"stratum_b\": \"W9\"
}" | pp

echo; echo "== 6. 受保护证据使目标无法失效：保护直达证据 WV-3（其自身即一条完整路径）"
echo "   -> protected_unreachable，reachable=false，retraction_count=null，"
echo "      simulated_* 给出仅保留受保护证据后仍成立的关系与路径 [WV-3] =="
curl -s -X POST "$BASE/relationship/withdrawal-analysis" -H 'Content-Type: application/json' -d "{
  \"expected_revision\": $REV,
  \"stratum_a\": \"W1\",
  \"stratum_b\": \"W3\",
  \"protected_evidence\": [\"WV-3\"]
}" | pp

echo; echo "== 7. 受保护但不独占路径：保护同一期桥 WV-1（不直达 W3），仍可使关系未定"
echo "   -> 撤回 WV-3 后只剩经 W2 的路径；要彻底断开还须再撤 WV-2：最少 2 条 [WV-2, WV-3] =="
curl -s -X POST "$BASE/relationship/withdrawal-analysis" -H 'Content-Type: application/json' -d "{
  \"expected_revision\": $REV,
  \"stratum_a\": \"W1\",
  \"stratum_b\": \"W3\",
  \"protected_evidence\": [\"WV-1\"]
}" | pp

echo; echo "== 8. 明确拒绝（只读，不改变任何状态） =="
echo "-- 8a. 修订号过期：STALE_REVISION（409，details.current_revision） --"
curl -s -X POST "$BASE/relationship/withdrawal-analysis" -H 'Content-Type: application/json' -d '{
  "expected_revision": 999999, "stratum_a": "W1", "stratum_b": "W3"
}' | pp
echo "-- 8b. 地层未登记：INVALID_STRATUM（400） --"
curl -s -X POST "$BASE/relationship/withdrawal-analysis" -H 'Content-Type: application/json' -d "{
  \"expected_revision\": $REV, \"stratum_a\": \"W1\", \"stratum_b\": \"WX\"
}" | pp
echo "-- 8c. 两个地层相同：DUPLICATE_STRATUM（400） --"
curl -s -X POST "$BASE/relationship/withdrawal-analysis" -H 'Content-Type: application/json' -d "{
  \"expected_revision\": $REV, \"stratum_a\": \"W1\", \"stratum_b\": \"W1\"
}" | pp
echo "-- 8d. 受保护证据不存在 / 已撤回：INVALID_PROTECTED_EVIDENCE（400） --"
curl -s -X POST "$BASE/relationship/withdrawal-analysis" -H 'Content-Type: application/json' -d "{
  \"expected_revision\": $REV, \"stratum_a\": \"W1\", \"stratum_b\": \"W3\",
  \"protected_evidence\": [\"WV-404\"]
}" | pp

echo; echo "== 9. 确认分析全程只读：修订号仍为 $REV，生效断言未变化 =="
curl -s "$BASE/revision" | pp
curl -s "$BASE/assertions?status=active" | python3 -c '
import sys, json
rows = json.load(sys.stdin)
wv = sorted(r["evidence_id"] for r in rows if r["evidence_id"].startswith("WV-"))
print("WV-* active:", wv)
assert wv == ["WV-1", "WV-2", "WV-3", "WV-4"], wv
print("分析无写入（只读成立）")'

echo; echo "全部撤回承受力分析示例执行完毕（正式状态未被修改）。"
