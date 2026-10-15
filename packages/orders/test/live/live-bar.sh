#!/usr/bin/env bash
# Live-transaction bar for DeepCoreRangeOrders + DeepCoreDCA (CLAUDE.md "Contract acceptance bar" 2).
# Runs against a PLAIN ANVIL the caller started (RPC, default http://127.0.0.1:8545). Devnet only: the
# setup script refuses any chain id but 31337. Keys are anvil's public dev keys.
#   FOUNDRY_PROFILE=default|legacy RPC=... bash test/live/live-bar.sh
set -u
RPC=${RPC:-http://127.0.0.1:8545}
cd "$(dirname "$0")/../.."
LOG=${LIVE_LOG:-/dev/stdout}

# anvil dev accounts (public test keys)
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
K1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d   # ALICE
K2=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a   # BOB
K3=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6   # KEEPER
K4=0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a   # SITE
K5=0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba   # STRANGER
K9=0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6   # SAFE stand-in
A0=$(cast wallet address $K0); ALICE=$(cast wallet address $K1); BOB=$(cast wallet address $K2)
KEEPER=$(cast wallet address $K3); SITE=$(cast wallet address $K4); STRANGER=$(cast wallet address $K5)
SAFE=$(cast wallet address $K9)
ZERO=0x0000000000000000000000000000000000000000

declare -A TX
PASS=0; FAILN=0; CHECKS=0; READS=0
note() { echo "$*" >> "$LOG"; }
fail() { FAILN=$((FAILN+1)); note "UNEXPECTED: $*"; }

# ok <fn-label> <key> <to> <sig> [args...] [-- value]
send() {
  local want=$1 label=$2 key=$3 to=$4 sig=$5; shift 5
  local extra=()
  if [ "$want" = bad ]; then extra=(--gas-limit 3000000); fi
  local out status
  local sigarg=(); [ -n "$sig" ] && sigarg=("$sig")
  out=$(cast send --rpc-url "$RPC" --private-key "$key" "${extra[@]}" "$to" "${sigarg[@]}" "$@" --json 2>&1)
  status=$(echo "$out" | sed -n 's/.*"status":"\(0x[0-9a-f]*\)".*/\1/p' | head -1)
  label="$CTX.$label"
  TX[$label]=$(( ${TX[$label]:-0} + 1 ))
  if [ "$want" = ok ] && [ "$status" = "0x1" ]; then PASS=$((PASS+1)); note "ok   $label";
  elif [ "$want" = bad ] && [ "$status" = "0x0" ]; then PASS=$((PASS+1)); note "ref  $label (mined revert)";
  else fail "$want $label status=$status $(echo "$out" | head -c 300)"; fi
}
ok() { send ok "$@"; }
bad() { send bad "$@"; }
okv() { local v=$1; shift; local label=$1 key=$2 to=$3 sig=$4; shift 4; send ok "$label" "$key" "$to" "$sig" "$@" --value "$v"; }
badv() { local v=$1; shift; local label=$1 key=$2 to=$3 sig=$4; shift 4; send bad "$label" "$key" "$to" "$sig" "$@" --value "$v"; }
READF=$(mktemp)
call() { echo r >> "$READF"; cast call --rpc-url "$RPC" "$@" | awk '{print $1}'; }
eq() { CHECKS=$((CHECKS+1)); if [ "$1" != "$2" ]; then fail "check $3: got $1 want $2"; else note "chk  $3"; fi; }
bal() { if [ "$1" = "$ZERO" ]; then cast balance --rpc-url "$RPC" "$2"; else cast call --rpc-url "$RPC" "$1" "balanceOf(address)(uint256)" "$2" | awk '{print $1}'; fi; }
warp() { cast rpc --rpc-url "$RPC" evm_increaseTime "$1" >/dev/null; cast rpc --rpc-url "$RPC" evm_mine >/dev/null; }
sub() { python -c "print($1 - $2)"; }

note "== setup ($(cast chain-id --rpc-url $RPC), profile ${FOUNDRY_PROFILE:-default})"
SETUP=$(LIVE_SAFE=$SAFE LIVE_PEOPLE="$A0,$ALICE,$BOB,$KEEPER,$SITE,$STRANGER" \
  forge script test/live/LiveBarSetup.s.sol --rpc-url "$RPC" --private-key $K0 --broadcast --slow 2>&1)
addr() { echo "$SETUP" | sed -n "s/.*ADDR $1 \(0x[0-9a-fA-F]*\).*/\1/p" | head -1; }
CL=$(addr cl); BIN=$(addr bin); ROUTER=$(addr router); T0=$(addr t0); T1=$(addr t1); ORDERS=$(addr orders); DCA=$(addr dca)
[ -n "$ORDERS" ] || { echo "$SETUP" | tail -30; exit 2; }
[ "$(cast code --rpc-url "$RPC" "$DCA" | wc -c)" -gt 100 ] || { note "SETUP FAILED: dca has no code"; echo "$SETUP" | tail -40 >> "$LOG"; exit 2; }
note "orders=$ORDERS dca=$DCA cl=$CL bin=$BIN"
for k in $K1 $K2 $K3 $K4 $K5; do
  for t in $T0 $T1; do for s in $ORDERS $DCA $ROUTER; do
    cast send --rpc-url "$RPC" --private-key $k $t "approve(address,uint256)" $s 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff >/dev/null
  done; done
done

P=0x00000000000000000000000000000000000000000000000000000000000a0000
KEY="($T0,$T1,$ZERO,$CL,3000,$P)"
KEYN="($ZERO,$T1,$ZERO,$CL,3000,$P)"
KEYB="($T0,$T1,$ZERO,$BIN,3000,$P)"
PLACE="place(((address,address,address,address,uint24,bytes32),int24,bool,uint256,uint128,address,uint16))"
SWAP="swap((address,address,address,address,uint24,bytes32),(bool,int256,uint160),(bool,bool),bytes)"
S120=79704936542881865393936269312
SM130=78714875113025805612897796096
SM500=77272108795590580476229713920

########################################## RANGE ORDERS ##########################################
CTX=orders
note "== range orders"
eq "$(call $ORDERS 'protocolFeeBps()(uint16)')" 10 "fee 10 bps at deploy"
eq "$(call $ORDERS 'owner()(address)')" "$SAFE" "owner is the Safe"
ok place $K1 $ORDERS "$PLACE" "($KEY,100,true,1000000000000000000,1000000000000000,$SITE,5)"
ok place $K2 $ORDERS "$PLACE" "($KEY,100,true,3000000000000000000,0,$ZERO,0)"
ok place $K1 $ORDERS "$PLACE" "($KEYN,-110,false,2000000000000000000,0,$ZERO,0)"
okv 1001000000000000000 place $K1 $ORDERS "$PLACE" "($KEYN,100,true,1000000000000000000,1000000000000000,$ZERO,0)"
bad place $K1 $ORDERS "$PLACE" "($KEY,0,true,1000000000000000000,0,$ZERO,0)"      # in range
bad place $K1 $ORDERS "$PLACE" "($KEY,105,true,1000000000000000000,0,$ZERO,0)"    # unaligned
badv 1 place $K1 $ORDERS "$PLACE" "($KEY,100,true,1000000000000000000,0,$ZERO,0)" # value on ERC-20
bad place $K1 $ORDERS "$PLACE" "(($T0,$T1,$ZERO,$CL,3000,0x00000000000000000000000000000000000000000000000000000000000a0010),100,true,1,0,$ZERO,0)" # trap bit
# launch pools are refused: by guard bitmap (three generations) and by the address list
BEEF=0x000000000000000000000000000000000000bEEF
DEAD=0x000000000000000000000000000000000000dEaD
for bm in 0041 08c1 0cc1; do
  bad place $K1 $ORDERS "$PLACE" "(($T0,$T1,$BEEF,$CL,3000,0x00000000000000000000000000000000000000000000000000000000000a$bm),100,true,1000000000000000000,0,$ZERO,0)"
done
bad place $K1 $ORDERS "$PLACE" "(($T0,$T1,$DEAD,$CL,3000,0x00000000000000000000000000000000000000000000000000000000000a0080),100,true,1000000000000000000,0,$ZERO,0)"
eq "$(call $ORDERS 'isLaunchGuard(address)(bool)' $DEAD)" true "listed guard"
eq "$(call $ORDERS 'isLaunchGuard(address)(bool)' $SITE)" false "an ordinary address is not a guard"
eq "$(call $ORDERS 'isLaunchPool((address,address,address,address,uint24,bytes32))(bool)' "$KEY")" false "the plain pool is not a launch pool"
eq "$(call $ORDERS 'isLaunchPool((address,address,address,address,uint24,bytes32))(bool)' "($T0,$T1,$BEEF,$CL,3000,0x00000000000000000000000000000000000000000000000000000000000a0cc1)")" true "a guard-bitmap key is a launch pool"
eq "$(call $ORDERS 'isCrossed(uint256)(bool)' 1)" false "epoch 1 not crossed"
eq "$(call $ORDERS 'openEpochOf(bytes32,int24,bool)(uint256)' $(cast keccak $(cast abi-encode 'f((address,address,address,address,uint24,bytes32))' "$KEY")) 100 true)" 1 "open epoch 1"
eq "$(call $ORDERS 'nextOrderId()(uint256)')" 5 "four orders"
eq "$(bal $T0 $ORDERS)" "$(call $ORDERS 'totalOwed(address)(uint256)' $T0)" "orders t0 balance == owed (tips)"
bad execute $K3 $ORDERS "execute(uint256)" 1      # not crossed
bad execute $K3 $ORDERS "execute(uint256)" 999    # unknown
ok executeMany $K3 $ORDERS "executeMany(uint256[])" "[1,2,3]"  # none crossed: a no-op success
# cross epoch 1 (buy currency0 up through tick 110)
ok swap $K5 $ROUTER "$SWAP" "$KEY" "(false,-100000000000000000000000,$S120)" "(true,true)" 0x
eq "$(call $ORDERS 'isCrossed(uint256)(bool)' 1)" true "epoch 1 crossed"
KB=$(bal $T0 $KEEPER)
ok execute $K3 $ORDERS "execute(uint256)" 1
eq "$(sub $(bal $T0 $KEEPER) $KB)" 1000000000000000 "keeper got exactly the 1e15 tip"
bad execute $K3 $ORDERS "execute(uint256)" 1      # already filled
bad withdraw $K5 $ORDERS "withdraw(uint256,address)" 1 $STRANGER   # not maker
bad withdraw $K1 $ORDERS "withdraw(uint256,address)" 3 $ALICE      # not filled
AB=$(bal $T1 $ALICE)
ok withdraw $K1 $ORDERS "withdraw(uint256,address)" 1 $ALICE
ok withdraw $K2 $ORDERS "withdraw(uint256,address)" 2 $BOB
bad withdraw $K1 $ORDERS "withdraw(uint256,address)" 1 $ALICE      # already withdrawn
eq "$(bal $T1 $ORDERS)" "$(call $ORDERS 'totalOwed(address)(uint256)' $T1)" "orders t1 balance == owed after withdrawals"
# cancel: untouched native-pool sell1 order 3
ok cancel $K1 $ORDERS "cancel(uint256,address)" 3 $ALICE
bad cancel $K1 $ORDERS "cancel(uint256,address)" 3 $ALICE          # unknown now
ok place $K2 $ORDERS "$PLACE" "($KEY,200,true,1000000000000000000,0,$SITE,10)"   # order 5
bad cancel $K5 $ORDERS "cancel(uint256,address)" 5 $STRANGER       # not maker
ok cancel $K2 $ORDERS "cancel(uint256,address)" 5 $BOB
ok place $K2 $ORDERS "$PLACE" "($KEY,-200,false,1000000000000000000,0,$ZERO,0)"  # order 6, sell1 below
ok cancel $K2 $ORDERS "cancel(uint256,address)" 6 $BOB
# native epoch (order 4): cross keyN upward, executeMany
ok swap $K5 $ROUTER "$SWAP" "$KEYN" "(false,-100000000000000000000000,$S120)" "(true,true)" 0x
ok executeMany $K3 $ORDERS "executeMany(uint256[])" "[3,999,4]"
eq "$(call $ORDERS 'isCrossed(uint256)(bool)' 3)" false "filled epoch no longer reports crossed"
ok withdraw $K1 $ORDERS "withdraw(uint256,address)" 4 $ALICE
bad cancel $K1 $ORDERS "cancel(uint256,address)" 4 $ALICE          # unknown after withdraw
eq "$(cast balance --rpc-url $RPC $ORDERS)" "$(call $ORDERS 'totalOwed(address)(uint256)' $ZERO)" "orders native balance == owed"
# fees
PO=$(call $ORDERS 'protocolOwed(address)(uint256)' $T1)
SB=$(bal $T1 $SAFE)
ok flushProtocolFees $K5 $ORDERS "flushProtocolFees(address)" $T1
eq "$(sub $(bal $T1 $SAFE) $SB)" "$PO" "flush paid exactly protocolOwed to the Safe"
bad flushProtocolFees $K5 $ORDERS "flushProtocolFees(address)" $T1
bad flushProtocolFees $K5 $ORDERS "flushProtocolFees(address)" $T0
ok claimIntegratorFees $K4 $ORDERS "claimIntegratorFees(address,address)" $T1 $SITE
bad claimIntegratorFees $K4 $ORDERS "claimIntegratorFees(address,address)" $T1 $SITE
bad claimIntegratorFees $K5 $ORDERS "claimIntegratorFees(address,address)" $T1 $STRANGER
# second integrator credit then claim again (third claim tx, happy)
ok place $K1 $ORDERS "$PLACE" "($KEY,300,true,1000000000000000000,0,$SITE,10)"   # order 7
ok swap $K5 $ROUTER "$SWAP" "$KEY" "(false,-100000000000000000000000,80508453602567373929651109888)" "(true,true)" 0x
ok execute $K3 $ORDERS "execute(uint256)" 6
ok executeMany $K3 $ORDERS "executeMany(uint256[])" "[6,999]"   # a filled and an unknown id: skipped, success
ok withdraw $K1 $ORDERS "withdraw(uint256,address)" 7 $ALICE
ok claimIntegratorFees $K4 $ORDERS "claimIntegratorFees(address,address)" $T1 $SITE
ok flushProtocolFees $K5 $ORDERS "flushProtocolFees(address)" $T1

governance() {
  local C=$1
  ok setProtocolFee $K9 $C "setProtocolFee(uint16)" 30                 # increase: scheduled
  eq "$(call $C 'protocolFeeBps()(uint16)')" 10 "increase not live yet"
  bad setProtocolFee $K5 $C "setProtocolFee(uint16)" 1                  # stranger
  bad setProtocolFee $K9 $C "setProtocolFee(uint16)" 51                 # above cap
  ok cancelPendingProtocolFee $K9 $C "cancelPendingProtocolFee()"
  bad cancelPendingProtocolFee $K9 $C "cancelPendingProtocolFee()"      # nothing pending
  bad cancelPendingProtocolFee $K5 $C "cancelPendingProtocolFee()"      # stranger
  ok setProtocolFee $K9 $C "setProtocolFee(uint16)" 40
  ok cancelPendingProtocolFee $K9 $C "cancelPendingProtocolFee()"
  ok setProtocolFee $K9 $C "setProtocolFee(uint16)" 5                   # decrease: immediate
  eq "$(call $C 'protocolFeeBps()(uint16)')" 5 "decrease immediate"
  ok setProtocolFee $K9 $C "setProtocolFee(uint16)" 10
  warp 604800
  eq "$(call $C 'protocolFeeBps()(uint16)')" 10 "increase applied by time alone"
  bad renounceOwnership $K9 $C "renounceOwnership()"
  bad renounceOwnership $K5 $C "renounceOwnership()"
  bad renounceOwnership $K9 $C "renounceOwnership()"
  # rescue: strays only
  cast send --rpc-url $RPC --private-key $K5 $T0 "transfer(address,uint256)" $C 7000000000000000000 >/dev/null
  RB=$(bal $T0 $BOB)
  ok rescueSurplus $K9 $C "rescueSurplus(address,address)" $T0 $BOB
  eq "$(sub $(bal $T0 $BOB) $RB)" 7000000000000000000 "rescued exactly the stray"
  bad rescueSurplus $K9 $C "rescueSurplus(address,address)" $T0 $BOB   # nothing above owed
  bad rescueSurplus $K5 $C "rescueSurplus(address,address)" $T1 $STRANGER
  cast send --rpc-url $RPC --private-key $K5 $T1 "transfer(address,uint256)" $C 1 >/dev/null
  ok rescueSurplus $K9 $C "rescueSurplus(address,address)" $T1 $SAFE
  # two-step ownership
  bad transferOwnership $K5 $C "transferOwnership(address)" $STRANGER
  ok transferOwnership $K9 $C "transferOwnership(address)" $BOB
  bad acceptOwnership $K5 $C "acceptOwnership()"
  ok acceptOwnership $K2 $C "acceptOwnership()"
  ok transferOwnership $K2 $C "transferOwnership(address)" $SAFE
  ok acceptOwnership $K9 $C "acceptOwnership()"
  ok transferOwnership $K9 $C "transferOwnership(address)" $SAFE        # self, then accept
  ok acceptOwnership $K9 $C "acceptOwnership()"
  bad acceptOwnership $K2 $C "acceptOwnership()"
  eq "$(call $C 'owner()(address)')" "$SAFE" "owner back to the Safe"
  bad lockAcquired $K5 $C "lockAcquired(bytes)" 0x
  bad lockAcquired $K9 $C "lockAcquired(bytes)" 0x
  bad lockAcquired $K3 $C "lockAcquired(bytes)" 0x1234
  badv 1 receive $K5 $C ""
  badv 1 receive $K9 $C ""
  badv 1000 receive $K3 $C ""
}
governance $ORDERS

################################################ DCA ##############################################
CTX=dca
note "== dca"
CREATE="create(((address,address,address,address,uint24,bytes32),bool,uint128,uint128,uint32,uint32,uint64,uint64,uint256,address,address,uint16))"
NOW=$(cast block --rpc-url $RPC latest -f timestamp)
DL=$((NOW + 30*86400))
HALF=39614081257132168796771975168   # 0.5 * 2^96
TIGHT=87151178765690771352898345369 # 1.10 * 2^96, above the pool price
ok create $K2 $DCA "$CREATE" "($KEY,true,1000000000000000000,1000000000000000,3,60,0,$DL,$HALF,$ALICE,$SITE,5)"   # plan 1
okv 2002000000000000000 create $K2 $DCA "$CREATE" "($KEYN,true,1000000000000000000,1000000000000000,2,60,0,$DL,$HALF,$ALICE,$ZERO,0)" # plan 2 native in
ok create $K2 $DCA "$CREATE" "($KEYB,false,1000000000000000000,0,2,60,0,$DL,$HALF,$ALICE,$ZERO,0)"  # plan 3 bin
bad create $K2 $DCA "$CREATE" "($KEY,true,1000000000000000000,0,3,59,0,$DL,$HALF,$ALICE,$ZERO,0)"     # interval < 60
bad create $K2 $DCA "$CREATE" "(($T0,$T1,$ZERO,$ROUTER,3000,$P),true,1,0,1,60,0,$DL,$HALF,$ALICE,$ZERO,0)" # wrong manager
badv 1 create $K2 $DCA "$CREATE" "($KEY,true,1,0,1,60,0,$DL,$HALF,$ALICE,$ZERO,0)"                     # value on ERC-20
eq "$(bal $T0 $DCA)" "$(call $DCA 'totalOwed(address)(uint256)' $T0)" "dca t0 escrow == owed"
eq "$(call $DCA 'totalOwed(address)(uint256)' $T0)" 3003000000000000000 "plan 1 escrow 3 x (1e18 + 1e15)"
eq "$(call $DCA 'isDue(uint256)(bool)' 1)" true "plan 1 due"
KB=$(bal $T0 $KEEPER); AB=$(bal $T1 $ALICE)
ok execute $K3 $DCA "execute(uint256)" 1
eq "$(sub $(bal $T0 $KEEPER) $KB)" 1000000000000000 "dca tip exactly 1e15"
eq "$(call $DCA 'isDue(uint256)(bool)' 1)" false "plan 1 not due after a slice"
bad execute $K3 $DCA "execute(uint256)" 1     # not due
ok execute $K3 $DCA "execute(uint256)" 2      # native in
ok execute $K3 $DCA "execute(uint256)" 3      # bin
bad execute $K3 $DCA "execute(uint256)" 99    # unknown
ok create $K1 $DCA "$CREATE" "($KEY,true,1000000000000000000,0,2,60,0,$DL,$TIGHT,$ALICE,$ZERO,0)"     # plan 4 tight bound
bad execute $K3 $DCA "execute(uint256)" 4     # below the user's bound
warp 61
ok execute $K3 $DCA "execute(uint256)" 1
eq "$(bal $T0 $DCA)" "$(call $DCA 'totalOwed(address)(uint256)' $T0)" "dca t0 balance == owed after slices"
eq "$(bal $T1 $DCA)" "$(call $DCA 'totalOwed(address)(uint256)' $T1)" "dca t1 balance == owed (fee credit)"
bad cancel $K5 $DCA "cancel(uint256,address)" 2 $STRANGER   # not owner
bad cancel $K9 $DCA "cancel(uint256,address)" 2 $SAFE       # the Safe cannot reach escrow
BB=$(cast balance --rpc-url $RPC $BOB)
ok cancel $K2 $DCA "cancel(uint256,address)" 2 $STRANGER    # owner sends the rest anywhere
ok cancel $K1 $DCA "cancel(uint256,address)" 4 $ALICE
TB=$(bal $T0 $BOB)
ok cancel $K2 $DCA "cancel(uint256,address)" 1 $BOB
eq "$(sub $(bal $T0 $BOB) $TB)" 1001000000000000000 "plan 1 refund exactly one slice + tip"
bad cancel $K2 $DCA "cancel(uint256,address)" 1 $BOB        # gone
eq "$(call $DCA 'totalOwed(address)(uint256)' $ZERO)" 0 "native escrow fully returned"
PO=$(call $DCA 'protocolOwed(address)(uint256)' $T1)
SB=$(bal $T1 $SAFE)
ok flushProtocolFees $K5 $DCA "flushProtocolFees(address)" $T1
eq "$(sub $(bal $T1 $SAFE) $SB)" "$PO" "dca flush paid exactly protocolOwed"
ok flushProtocolFees $K5 $DCA "flushProtocolFees(address)" $T0
bad flushProtocolFees $K5 $DCA "flushProtocolFees(address)" $T1
ok claimIntegratorFees $K4 $DCA "claimIntegratorFees(address,address)" $T1 $SITE
bad claimIntegratorFees $K4 $DCA "claimIntegratorFees(address,address)" $T1 $SITE
bad claimIntegratorFees $K5 $DCA "claimIntegratorFees(address,address)" $T0 $STRANGER
ok create $K2 $DCA "$CREATE" "($KEY,true,1000000000000000000,0,1,60,0,$((DL+700000)),$HALF,$ALICE,$SITE,10)"  # plan 5
ok execute $K3 $DCA "execute(uint256)" 5
ok claimIntegratorFees $K4 $DCA "claimIntegratorFees(address,address)" $T1 $SITE
governance $DCA

note "== tally"
for k in $(printf '%s
' "${!TX[@]}" | sort); do note "$(printf '%-36s %d' "$k" "${TX[$k]}")"; done
TOTAL=0; for k in "${!TX[@]}"; do TOTAL=$((TOTAL + TX[$k])); done
READS=$(wc -l < "$READF" | tr -d " ")
note "TOTAL_TX=$TOTAL PASS=$PASS UNEXPECTED=$FAILN CHECKS=$CHECKS READS=$READS"
[ "$FAILN" = 0 ]
