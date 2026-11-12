#!/usr/bin/env bash
# Testnet probe: Ethereum Sepolia (origin + destination) <-> Lasna (Reactive testnet).
# Proves: ProbeGuard.Watch -> GuardReactive registers; ProbePool.Swap out of range, twice,
# more than `grace` apart -> GuardReactive requests a callback -> ProbeGuard.closeByReactive runs.
# Needs: .env with TEST_PRIVATE_KEY / TEST_ADDRESS, Ethereum Sepolia ETH on TEST_ADDRESS.
# Usage: script/probe.sh fund | deploy | run | status
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
export PATH="/c/Users/User/tools/foundry:$PATH"
FAUCET=0x9b9BB25f1A81078C544C829c5EB7822d747Cf434        # Ethereum Sepolia -> lREACT, 1 ETH = 100 lREACT
PROXY=0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4         # Reactive callback proxy on Ethereum Sepolia
SYSTEM=0x8888888888888888888888888888888888888888
STATE=.probe-state
touch $STATE; . ./$STATE
save() { echo "$1=$2" >> $STATE; }
bs() { cast "$@" --rpc-url "$ORIGIN_RPC"; }
ls_() { cast "$@" --rpc-url "$LASNA_RPC"; }

case "${1:-status}" in
fund)   # swap part of the Ethereum Sepolia ETH for lREACT
  AMT="${2:-0.02ether}"
  bs send $FAUCET "request(address)" "$TEST_ADDRESS" --value "$AMT" --private-key "$TEST_PRIVATE_KEY" | grep -E "status|transactionHash"
  ;;
deploy)
  RX=$(forge create src/GuardReactive.sol:GuardReactive --broadcast --rpc-url "$LASNA_RPC" --private-key "$TEST_PRIVATE_KEY" --value 0.5ether --constructor-args 11155111 | awk '/Deployed to/{print $3}')
  save RX "$RX"; echo "GuardReactive (Lasna): $RX"
  PG=$(forge create src/testnet/Probe.sol:ProbeGuard --broadcast --rpc-url "$ORIGIN_RPC" --private-key "$TEST_PRIVATE_KEY" --value 0.002ether --constructor-args $PROXY "$RX" | awk '/Deployed to/{print $3}')
  save PG "$PG"; echo "ProbeGuard (Ethereum Sepolia): $PG"
  PP=$(forge create src/testnet/Probe.sol:ProbePool --broadcast --rpc-url "$ORIGIN_RPC" --private-key "$TEST_PRIVATE_KEY" | awk '/Deployed to/{print $3}')
  save PP "$PP"; echo "ProbePool (Ethereum Sepolia): $PP"
  ls_ send "$RX" "setGuard(address)" "$PG" --private-key "$TEST_PRIVATE_KEY" | grep -E "status|transactionHash"
  bs send $PROXY "depositTo(address)" "$PG" --value 0.002ether --private-key "$TEST_PRIVATE_KEY" | grep -E "status|transactionHash"
  ;;
run)    # watch position #1 with range [-100,100) and a 60 s grace, then push the price out twice
  cast send --rpc-url "$ORIGIN_RPC" --private-key "$TEST_PRIVATE_KEY" "$PG" "watch(uint256,address,int24,int24,uint32)" 1 "$PP" -- -100 100 60 | grep -E "status|transactionHash"
  echo "waiting 20 s for Reactive to register the watch"; timeout 20 tail -f /dev/null || true
  bs send "$PP" "swapTo(int24)" 500 --private-key "$TEST_PRIVATE_KEY" | grep -E "status|transactionHash"
  echo "price is out of range; waiting 75 s (grace 60 s)"; timeout 75 tail -f /dev/null || true
  bs send "$PP" "swapTo(int24)" 510 --private-key "$TEST_PRIVATE_KEY" | grep -E "status|transactionHash"
  echo "waiting 40 s for the callback"; timeout 40 tail -f /dev/null || true
  "$0" status
  ;;
status)
  echo "wallet $TEST_ADDRESS"
  echo "  Ethereum Sepolia ETH: $(bs balance "$TEST_ADDRESS" --ether)"
  echo "  Lasna lREACT:     $(ls_ balance "$TEST_ADDRESS" --ether)"
  if [ -n "${RX:-}" ]; then
    echo "GuardReactive $RX  balance $(ls_ balance "$RX" --ether)  debt $(ls_ call $SYSTEM 'debt(address)(uint256)' "$RX")"
    echo "  position #1: $(ls_ call "$RX" 'positions(uint256)(address,int24,int24,uint32,uint64,bool)' 1 | tr '\n' ' ')"
  fi
  if [ -n "${PG:-}" ]; then
    echo "ProbeGuard $PG  closedAt(1) = $(bs call "$PG" 'closedAt(uint256)(uint256)' 1)"
  fi
  ;;
esac
