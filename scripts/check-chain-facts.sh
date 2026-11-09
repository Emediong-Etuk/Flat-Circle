#!/usr/bin/env bash
# Re-checks the chain facts in docs/CHAIN-FACTS.md. Needs Foundry's `cast`.
# Usage: RPC_URL=<rpc> ./scripts/check-chain-facts.sh
set -euo pipefail
R="${RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
U=0x5fc5360d0400a0fd4f2af552add042d716f1d168
W=0x5173b8eA6923c2d40267890D45C46a3480954773
A=0x0000000000000000000000000000000000000064

echo "chainId:          $(cast chain-id -r "$R")"
echo "L2 block (ArbSys): $(cast call $A 'arbBlockNumber()(uint256)' -r "$R")"
echo "arbOSVersion:     $(cast call $A 'arbOSVersion()(uint256)' -r "$R")"
for t in $U $W; do
  echo "--- $t"
  echo "  symbol:   $(cast call $t 'symbol()(string)' -r "$R")"
  echo "  decimals: $(cast call $t 'decimals()(uint8)' -r "$R")"
done
echo "USDG version():   $(cast call $U 'version()(string)' -r "$R" 2>&1 | head -1)"
echo "USDG paused():    $(cast call $U 'paused()(bool)' -r "$R")"
op() { printf "  %-12s " "$1"; cast call -r "$R" --create "$2" 2>&1 | head -1; }
echo "opcodes:"
op PUSH0  0x5f5f5260206000f3
op TSTORE 0x600160005d60005c60005260206000f3
op MCOPY  0x602a6000526020600060205e60206020f3
op PREVRANDAO 0x4460005260206000f3
L=$(cast call $A 'arbBlockNumber()(uint256)' -r "$R" | awk '{print $1}')
echo "arbBlockHash(L-1):   $(cast call $A 'arbBlockHash(uint256)(bytes32)' $((L-1)) -r "$R")"
echo "arbBlockHash(L-300): $(cast call $A 'arbBlockHash(uint256)(bytes32)' $((L-300)) -r "$R" 2>&1 | head -1)"
