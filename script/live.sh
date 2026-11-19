#!/usr/bin/env bash
# Live deploy: PositionGuard (+ its GuardMeter) on Base (8453) <-> GuardReactive, the clock, on Reactive mainnet (1597).
# Needs .env.live with LIVE_PRIVATE_KEY / LIVE_ADDRESS (a deploy-only wallet holding ETH on Base
# and REACT on Reactive). Set BASE_RPC / REACT_RPC to local forks to rehearse.
# Usage: script/live.sh deploy | status | stop | withdraw <amount-in-REACT>
# If a deploy transaction lands but the script dies before saving its address, add the address to
# the state file by hand (RX= / PM= / PG=) before running again, or a second copy gets deployed.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env.live}"
set -a; . "./$ENV_FILE"; set +a
export PATH="/c/Users/User/tools/foundry:$PATH"
BASE_RPC="${BASE_RPC:-https://mainnet.base.org}"
REACT_RPC="${REACT_RPC:-https://mainnet-rpc.rnk.dev/}"
STATE="${STATE:-.live-state}"

PROXY=0xCc780DdE33f56f55dE778D42c930959374a4a068    # Reactive callback proxy on Base mainnet
NPM=0x4857DB576eE0e45F10525eC59527BfD10beeC60b      # Aero Slipstream position manager
AERO=0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee
SUGAR=0x0AD09A66af0154a84e86F761313d02d0abB6edd5     # Aero SugarHelper
SYSTEM=0x8888888888888888888888888888888888888888
CRON1000=0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4   # keccak("Cron1000(uint256)"), ~every 17 min
CHECK_EVERY=3600                                     # hourly check
REVIEW_EVERY=86400                                   # daily review
RX_VALUE="${RX_VALUE:?set RX_VALUE, REACT left on GuardReactive (e.g. 100ether)}"
CB_VALUE="${CB_VALUE:?set CB_VALUE, ETH deposited for callbacks on Base (e.g. 0.0003ether)}"

touch "$STATE"; . "./$STATE"
save() { echo "$1=$2" >> "$STATE"; }
read_() { local v; v=$(cast "$@") || { echo "read failed: cast $*" >&2; exit 1; }; echo "$v"; }

# The state file belongs to one pair of chains: refuse to reuse it against others (e.g. a fork).
BASE_ID=$(read_ chain-id --rpc-url "$BASE_RPC"); REACT_ID=$(read_ chain-id --rpc-url "$REACT_RPC")
if [ -z "${CHAINS:-}" ]; then save CHAINS "$BASE_ID-$REACT_ID"; CHAINS="$BASE_ID-$REACT_ID"
elif [ "$CHAINS" != "$BASE_ID-$REACT_ID" ]; then echo "$STATE is for chains $CHAINS, RPCs are $BASE_ID-$REACT_ID"; exit 1; fi

# PoolMath runs inside the guard (DELEGATECALL), so the guard may only be linked to our exact code:
# byte for byte the compiled runtime.
check_pm() {
  local want got
  want=$(forge inspect src/lib/PoolMath.sol:PoolMath deployedBytecode | tr 'A-F' 'a-f')
  # older pipelines put the library's own address in a PUSH20 call-protection slot at the start
  if [ "${want:0:44}" = "0x730000000000000000000000000000000000000000" ]; then
    want="0x73$(echo "$1" | tr 'A-F' 'a-f' | sed 's/^0x//')${want:44}"
  fi
  # via-IR puts it in a PUSH32 right after ADDRESS: 6080604052 30 7f <32 bytes>
  if [ "${want:0:16}" = "0x6080604052307f" ] && [ "${want:16:64}" = "$(printf '0%.0s' {1..64})" ]; then
    want="0x6080604052307f000000000000000000000000$(echo "$1" | tr 'A-F' 'a-f' | sed 's/^0x//')${want:80}"
  fi
  got=$(read_ code "$1" --rpc-url "$BASE_RPC" | tr 'A-F' 'a-f')
  [ "$got" = "$want" ] || { echo "code at PoolMath $1 is not our PoolMath: refusing to link"; exit 1; }
}
ok() { grep -E "^status +1" >/dev/null || { echo "transaction failed"; exit 1; }; }

case "${1:-status}" in
deploy)
  [ -z "${RX:-}" ] && {
    RX=$(forge create src/GuardReactive.sol:GuardReactive --broadcast --rpc-url "$REACT_RPC" \
      --private-key "$LIVE_PRIVATE_KEY" --value "$RX_VALUE" --constructor-args 8453 | awk '/Deployed to/{print $3}')
    [ -n "$RX" ] || { echo "GuardReactive deploy failed"; exit 1; }
    save RX "$RX"; echo "GuardReactive (Reactive): $RX"; }
  [ -z "${PM:-}" ] && {
    PM=$(forge create src/lib/PoolMath.sol:PoolMath --broadcast --rpc-url "$BASE_RPC" \
      --private-key "$LIVE_PRIVATE_KEY" | awk '/Deployed to/{print $3}')
    [ -n "$PM" ] || { echo "PoolMath deploy failed"; exit 1; }
    save PM "$PM"; echo "PoolMath (Base): $PM"; }
  check_pm "$PM"
  [ -z "${PG:-}" ] && {
    PG=$(forge create src/PositionGuard.sol:PositionGuard --broadcast --rpc-url "$BASE_RPC" \
      --private-key "$LIVE_PRIVATE_KEY" --libraries "src/lib/PoolMath.sol:PoolMath:$PM" --constructor-args $NPM $AERO $PROXY "$RX" $SUGAR | awk '/Deployed to/{print $3}')
    [ -n "$PG" ] || { echo "PositionGuard deploy failed"; exit 1; }
    save PG "$PG"; echo "PositionGuard (Base): $PG"; }
  [ "$(read_ call "$RX" 'guard()(address)' --rpc-url "$REACT_RPC" | tr 'A-F' 'a-f')" = "$(echo "$PG" | tr 'A-F' 'a-f')" ] && WIRED=1
  [ -z "${WIRED:-}" ] && {
    cast send "$RX" "setGuard(address)" "$PG" --rpc-url "$REACT_RPC" --private-key "$LIVE_PRIVATE_KEY" | ok
    save WIRED 1; echo "wired: GuardReactive calls $PG"; }
  [ "$(read_ call "$RX" 'cronTopic()(uint256)' --rpc-url "$REACT_RPC")" != "0" ] && CLOCK=1
  [ -z "${CLOCK:-}" ] && {
    cast send "$RX" "start(uint256,uint32,uint32)" $CRON1000 $CHECK_EVERY $REVIEW_EVERY --rpc-url "$REACT_RPC" --private-key "$LIVE_PRIVATE_KEY" | ok
    save CLOCK 1; echo "clock on: check every ${CHECK_EVERY}s, review every ${REVIEW_EVERY}s (Cron1000)"; }
  [ -z "${FUNDED:-}" ] && {
    cast send $PROXY "depositTo(address)" "$PG" --value "$CB_VALUE" --rpc-url "$BASE_RPC" --private-key "$LIVE_PRIVATE_KEY" | ok
    save FUNDED 1; echo "callbacks funded: $CB_VALUE"; }
  "$0" status
  ;;
status)
  EB=$(read_ balance "$LIVE_ADDRESS" --ether --rpc-url "$BASE_RPC"); RB=$(read_ balance "$LIVE_ADDRESS" --ether --rpc-url "$REACT_RPC")
  echo "deploy wallet $LIVE_ADDRESS"; echo "  Base ETH:       $EB"; echo "  Reactive REACT: $RB"
  if [ -n "${RX:-}" ]; then
    A=$(read_ balance "$RX" --ether --rpc-url "$REACT_RPC"); D=$(read_ call $SYSTEM 'debt(address)(uint256)' "$RX" --rpc-url "$REACT_RPC")
    G=$(read_ call "$RX" 'guard()(address)' --rpc-url "$REACT_RPC"); C=$(read_ call "$RX" 'cronTopic()(uint256)' --rpc-url "$REACT_RPC")
    LC=$(read_ call "$RX" 'lastCheck()(uint64)' --rpc-url "$REACT_RPC"); LR=$(read_ call "$RX" 'lastReview()(uint64)' --rpc-url "$REACT_RPC")
    echo "GuardReactive $RX"; echo "  REACT $A  debt $D"; echo "  guard $G  cron ${C:0:12}…  last check $LC  last review $LR"
  fi
  if [ -n "${PG:-}" ]; then
    N=$(read_ call "$PG" 'reviewCount()(uint256)' --rpc-url "$BASE_RPC"); M=$(read_ call "$PG" 'meter()(address)' --rpc-url "$BASE_RPC")
    R=$(read_ call $PROXY 'reserves(address)(uint256)' "$PG" --rpc-url "$BASE_RPC"); DB=$(read_ call $PROXY 'debts(address)(uint256)' "$PG" --rpc-url "$BASE_RPC")
    echo "PositionGuard $PG  positions $N  meter $M"; echo "  callback reserve $R  debt $DB"
  fi
  ;;
stop)
  cast send "$RX" "stop()" --rpc-url "$REACT_RPC" --private-key "$LIVE_PRIVATE_KEY" | ok; echo "clock off"
  ;;
withdraw)
  cast send "$RX" "withdraw(address,uint256)" "$LIVE_ADDRESS" "${2:?amount, e.g. 50ether}" --rpc-url "$REACT_RPC" --private-key "$LIVE_PRIVATE_KEY" | ok
  echo "REACT back to $LIVE_ADDRESS"
  ;;
esac
