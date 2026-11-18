#!/usr/bin/env bash
# Live deploy: PositionGuard on Base (8453) <-> GuardReactive on Reactive mainnet (1597).
# Needs .env.live with LIVE_PRIVATE_KEY / LIVE_ADDRESS (a deploy-only wallet holding ETH on Base
# and REACT on Reactive). Set BASE_RPC / REACT_RPC to local forks to rehearse.
# Usage: script/live.sh deploy | status
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
CRON10000=0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56  # ~every 2-3 h
REVIEW_EVERY=86400                                   # review at most once a day
RX_VALUE="${RX_VALUE:-4000ether}"                    # REACT left on GuardReactive for its work
CB_VALUE="${CB_VALUE:-0.001ether}"                   # ETH deposited for callbacks on Base

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
    save WIRED 1; echo "wired: GuardReactive watches $PG"; }
  [ "$(read_ call "$RX" 'cronTopic()(uint256)' --rpc-url "$REACT_RPC")" != "0" ] && REVIEW=1
  [ -z "${REVIEW:-}" ] && {
    cast send "$RX" "setReview(uint256,uint32)" $CRON10000 $REVIEW_EVERY --rpc-url "$REACT_RPC" --private-key "$LIVE_PRIVATE_KEY" | ok
    save REVIEW 1; echo "daily review on (Cron10000, once per ${REVIEW_EVERY}s)"; }
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
    echo "GuardReactive $RX"; echo "  REACT $A  debt $D"; echo "  guard $G  cron ${C:0:12}…"
  fi
  if [ -n "${PG:-}" ]; then
    N=$(read_ call "$PG" 'reviewCount()(uint256)' --rpc-url "$BASE_RPC")
    echo "PositionGuard $PG  reviews $N"
  fi
  ;;
esac
