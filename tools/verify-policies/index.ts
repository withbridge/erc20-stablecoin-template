import {
  createPublicClient,
  http,
  parseAbi,
  getAddress,
  encodeFunctionData,
  decodeFunctionResult,
  type Address,
  type PublicClient,
} from 'viem'
import { defineChain } from 'viem'
import { readFileSync } from 'node:fs'

interface TokenEntry {
  address: string
  policy_type: 'transfer' | 'mint_recipient'
}

interface ChainEntry {
  name: string
  rpc_url: string
  chain_id: number
  auth_registry: string
  tokens: TokenEntry[]
}

interface MultiChainInput {
  name: string
  expected_addresses: string[]
  expect?: 'blocked' | 'authorized'
  chains: ChainEntry[]
}

interface SingleChainInput {
  name: string
  rpc_url: string
  chain_id: number
  auth_registry: string
  token: string
  policy_type: 'transfer' | 'mint_recipient'
  expected_addresses: string[]
}

function isMultiChainInput(input: unknown): input is MultiChainInput {
  return typeof input === 'object' && input !== null && 'chains' in input
}

const tokenAbi = parseAbi([
  'function symbol() view returns (string)',
  'function name() view returns (string)',
  'function getTransferPolicyId() view returns (uint64)',
  'function getMintRecipientPolicyId() view returns (uint64)',
])

const registryAbi = parseAbi([
  'function policyData(uint64 policyId) view returns (uint8 policyType, address admin, uint64 parentPolicyId, bool parentPolicyIdIsSet)',
  'function isAuthorized(uint64 policyId, address user) view returns (bool)',
])

const MULTICALL3 = '0xcA11bde05977b3631167028862bE2a173976CA11' as Address
const multicall3Abi = parseAbi([
  'function aggregate3((address target, bool allowFailure, bytes callData)[] calls) view returns ((bool success, bytes returnData)[])',
])

type Multicall3Call = { target: Address; allowFailure: boolean; callData: `0x${string}` }
type Multicall3Result = readonly { success: boolean; returnData: `0x${string}` }[]

async function rawMulticall3(client: PublicClient, calls: Multicall3Call[]): Promise<Multicall3Result> {
  return client.readContract({
    address: MULTICALL3,
    abi: multicall3Abi,
    functionName: 'aggregate3',
    args: [calls],
  }) as Promise<Multicall3Result>
}

async function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function withRetry<T>(fn: () => Promise<T>, retries = 5, baseDelay = 2000): Promise<T> {
  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      return await fn()
    } catch (err: any) {
      if (attempt === retries) {
        const msg = err?.shortMessage ?? err?.message ?? String(err)
        console.error(`  ✗ RPC error (giving up after ${retries} retries): ${msg}`)
        throw err
      }
      const delay = baseDelay * 2 ** attempt
      const msg = err?.shortMessage ?? err?.message ?? String(err)
      const details = err?.details ?? ''
      console.log(`  ⟳ RPC error (attempt ${attempt + 1}/${retries}), retrying in ${delay}ms...`)
      console.log(`    ${msg}${details ? ` — ${details}` : ''}`)
      await sleep(delay)
    }
  }
  throw new Error('unreachable')
}

function parseArgs(argv: string[]): { inputs: string[]; chainFilter: string[] } {
  const inputs: string[] = []
  const chainFilter: string[] = []
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--input' || arg === '-i') {
      inputs.push(argv[++i])
    } else if (arg === '--chain' || arg === '-c') {
      chainFilter.push(argv[++i])
    } else if (arg === '--help' || arg === '-h') {
      usageAndExit(0)
    }
  }
  if (inputs.length === 0) {
    console.error('Error: at least one --input file required')
    usageAndExit(1)
  }
  return { inputs, chainFilter }
}

function usageAndExit(code: number): never {
  console.error('Usage: tsx index.ts --input <file.json> [--chain <name> ...]')
  console.error('')
  console.error('Verifies that expected addresses are correctly enforced on-chain.')
  console.error('')
  console.error('Input files can be either format:')
  console.error('  Single-chain:  { token, policy_type, expected_addresses, ... }')
  console.error('  Multi-chain:   { expected_addresses, chains: [{ tokens: [...] }, ...] }')
  console.error('')
  console.error('Options:')
  console.error('  --input, -i  Input JSON file (required, repeatable)')
  console.error('  --chain, -c  Filter to specific chain name(s) in multi-chain inputs (optional)')
  process.exit(code)
}

interface VerifyResult {
  label: string
  passed: number
  failed: number
  mismatches: string[]
}

function createClient(chainId: number, rpcUrl: string): PublicClient {
  const chain = defineChain({
    id: chainId,
    name: `chain-${chainId}`,
    nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
    contracts: {
      multicall3: { address: '0xcA11bde05977b3631167028862bE2a173976CA11' },
    },
  })
  return createPublicClient({ chain, transport: http(rpcUrl) }) as PublicClient
}

async function verifyTokenPolicy(
  client: PublicClient,
  chainName: string,
  chainId: number,
  authRegistry: Address,
  token: Address,
  policyType: 'transfer' | 'mint_recipient',
  addresses: Address[],
  expectOverride?: 'blocked' | 'authorized',
): Promise<VerifyResult> {
  const policyFn = policyType === 'transfer' ? 'getTransferPolicyId' : 'getMintRecipientPolicyId'
  const metaResults = await withRetry(() => rawMulticall3(client, [
    { target: token, allowFailure: true, callData: encodeFunctionData({ abi: tokenAbi, functionName: 'symbol' }) },
    { target: token, allowFailure: true, callData: encodeFunctionData({ abi: tokenAbi, functionName: 'name' }) },
    { target: token, allowFailure: true, callData: encodeFunctionData({ abi: tokenAbi, functionName: policyFn }) },
  ]))
  const metaLabels = ['symbol', 'name', policyFn]
  for (let mi = 0; mi < metaResults.length; mi++) {
    if (!metaResults[mi].success) {
      throw new Error(`Failed to call ${metaLabels[mi]}() on ${token} — contract may not implement this function`)
    }
  }
  const symbol = decodeFunctionResult({ abi: tokenAbi, functionName: 'symbol', data: metaResults[0].returnData }) as string
  const name = decodeFunctionResult({ abi: tokenAbi, functionName: 'name', data: metaResults[1].returnData }) as string
  const policyId = decodeFunctionResult({ abi: tokenAbi, functionName: policyFn, data: metaResults[2].returnData }) as bigint

  const policyDataResult = await withRetry(() => client.readContract({
    address: authRegistry,
    abi: registryAbi,
    functionName: 'policyData',
    args: [policyId],
  }))
  const [policyTypeRaw, admin] = policyDataResult as readonly [number, Address, bigint, boolean]

  const policyTypeName = policyTypeRaw === 0 ? 'WHITELIST' : 'BLACKLIST'
  const expectBlocked = expectOverride
    ? expectOverride === 'blocked'
    : policyTypeName === 'BLACKLIST'
  const label = `${chainName} — ${symbol} ${policyType}`

  console.log('')
  console.log(`━━━ ${label} ━━━`)
  console.log(`Token:    ${token} (${symbol} / ${name})`)
  console.log(`Chain:    ${chainName} (${chainId})`)
  console.log(`Registry: ${authRegistry}`)
  console.log(`Policy:   ${policyType} → ID ${policyId} (${policyTypeName})`)
  console.log(`Admin:    ${admin}`)
  console.log(`Expect:   ${expectBlocked ? 'blocked (isAuthorized=false)' : 'authorized (isAuthorized=true)'}`)
  console.log('')
  console.log(`Checking ${addresses.length} addresses...`)

  let passed = 0
  let failed = 0
  const mismatches: string[] = []

  const batchSize = 80
  for (let i = 0; i < addresses.length; i += batchSize) {
    if (i > 0) await sleep(2000)
    const batch = addresses.slice(i, i + batchSize)

    const calls: Multicall3Call[] = batch.map((addr) => ({
      target: authRegistry,
      allowFailure: true,
      callData: encodeFunctionData({ abi: registryAbi, functionName: 'isAuthorized', args: [policyId, addr] }),
    }))

    const results = await withRetry(() => rawMulticall3(client, calls))

    for (let j = 0; j < batch.length; j++) {
      const addr = batch[j]
      const entry = results[j]
      if (!entry.success) {
        console.log(`  ✗ ${addr} RPC error`)
        mismatches.push(addr)
        failed++
        continue
      }
      const isAuthorized = decodeFunctionResult({
        abi: registryAbi,
        functionName: 'isAuthorized',
        data: entry.returnData,
      }) as boolean

      if (expectBlocked) {
        if (!isAuthorized) {
          passed++
        } else {
          console.log(`  ✗ ${addr} NOT blocked (expected blocked)`)
          mismatches.push(addr)
          failed++
        }
      } else {
        if (isAuthorized) {
          passed++
        } else {
          console.log(`  ✗ ${addr} NOT authorized (expected authorized)`)
          mismatches.push(addr)
          failed++
        }
      }
    }
  }

  console.log('')
  if (failed === 0) {
    console.log(`Result: ${passed}/${addresses.length} correct ✓`)
  } else {
    console.log(`Result: ${passed}/${addresses.length} correct, ${failed} mismatches ✗`)
  }

  return { label, passed, failed, mismatches }
}

async function processMultiChain(input: MultiChainInput, chainFilter: string[]): Promise<VerifyResult[]> {
  const addresses = input.expected_addresses.map((a) => getAddress(a) as Address)

  let chains = input.chains
  if (chainFilter.length > 0) {
    const filterLower = chainFilter.map((c) => c.toLowerCase())
    chains = chains.filter((c) => filterLower.includes(c.name.toLowerCase()))
    if (chains.length === 0) {
      const available = input.chains.map((c) => c.name).join(', ')
      throw new Error(`No chains matched filter [${chainFilter.join(', ')}]. Available: ${available}`)
    }
  }

  const tokenCount = chains.reduce((s, c) => s + c.tokens.length, 0)
  console.log(`${input.name}`)
  console.log(`${addresses.length} addresses × ${tokenCount} tokens across ${chains.length} chains`)

  const results: VerifyResult[] = []

  for (const chainEntry of chains) {
    if (chainEntry.tokens.length === 0) {
      console.log(`\n  ⊘ ${chainEntry.name}: no tokens configured, skipping`)
      continue
    }

    const client = createClient(chainEntry.chain_id, chainEntry.rpc_url)

    const reportedChainId = await withRetry(() => client.getChainId())
    if (reportedChainId !== chainEntry.chain_id) {
      throw new Error(`${chainEntry.name}: chain mismatch — RPC reports ${reportedChainId}, expected ${chainEntry.chain_id}`)
    }

    const authRegistry = getAddress(chainEntry.auth_registry) as Address

    for (let ti = 0; ti < chainEntry.tokens.length; ti++) {
      if (ti > 0) await sleep(5000)
      const tokenEntry = chainEntry.tokens[ti]
      const token = getAddress(tokenEntry.address) as Address
      try {
        const result = await verifyTokenPolicy(
          client, chainEntry.name, chainEntry.chain_id, authRegistry,
          token, tokenEntry.policy_type, addresses, input.expect,
        )
        results.push(result)
      } catch (err: any) {
        console.log(`\n  ✗ ${chainEntry.name} — ${tokenEntry.address}: ${err.message}`)
        results.push({ label: `${chainEntry.name} — ${tokenEntry.address}`, passed: 0, failed: addresses.length, mismatches: ['ERROR'] })
      }
    }
  }

  return results
}

async function processSingleChain(input: SingleChainInput): Promise<VerifyResult> {
  const client = createClient(input.chain_id, input.rpc_url)

  const reportedChainId = await withRetry(() => client.getChainId())
  if (reportedChainId !== input.chain_id) {
    throw new Error(`Chain mismatch: RPC reports ${reportedChainId}, expected ${input.chain_id}`)
  }

  const token = getAddress(input.token) as Address
  const authRegistry = getAddress(input.auth_registry) as Address
  const addresses = input.expected_addresses.map((a) => getAddress(a) as Address)

  return verifyTokenPolicy(
    client, `chain-${input.chain_id}`, input.chain_id, authRegistry,
    token, input.policy_type, addresses,
  )
}

async function main() {
  const { inputs, chainFilter } = parseArgs(process.argv.slice(2))
  const allResults: VerifyResult[] = []

  for (const file of inputs) {
    const raw = readFileSync(file, 'utf-8')
    const input = JSON.parse(raw)

    if (isMultiChainInput(input)) {
      const results = await processMultiChain(input, chainFilter)
      allResults.push(...results)
    } else {
      const result = await processSingleChain(input as SingleChainInput)
      allResults.push(result)
    }
  }

  const totalPassed = allResults.reduce((s, r) => s + r.passed, 0)
  const totalFailed = allResults.reduce((s, r) => s + r.failed, 0)
  const failedResults = allResults.filter((r) => r.mismatches.length > 0)

  if (allResults.length > 1) {
    console.log('')
    console.log('━━━ Summary ━━━')
    console.log(`Total: ${totalPassed + totalFailed} checks, ${totalPassed} passed, ${totalFailed} failed`)
  }

  if (failedResults.length > 0) {
    console.log('')
    console.log('Mismatches:')
    for (const { label, mismatches } of failedResults) {
      console.log(`  ${label}:`)
      for (const addr of mismatches) {
        console.log(`    ${addr}`)
      }
    }
    process.exit(1)
  }
}

main().catch((err) => {
  console.error('Error:', err.shortMessage ?? err.message ?? err)
  if (err.cause) console.error('Cause:', err.cause.shortMessage ?? err.cause.message ?? err.cause)
  process.exit(1)
})
