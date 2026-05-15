import {
  createPublicClient,
  http,
  parseAbi,
  getAddress,
  type Address,
  type PublicClient,
} from 'viem'
import { defineChain } from 'viem'
import { readFileSync } from 'node:fs'

interface PolicyInput {
  name: string
  rpc_url: string
  chain_id: number
  auth_registry: string
  token: string
  policy_type: 'transfer' | 'mint_recipient'
  expected_addresses: string[]
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

function parseArgs(argv: string[]): string[] {
  const inputs: string[] = []
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--input' || arg === '-i') {
      inputs.push(argv[++i])
    } else if (arg === '--help' || arg === '-h') {
      usageAndExit(0)
    }
  }
  if (inputs.length === 0) {
    console.error('Error: at least one --input file required')
    usageAndExit(1)
  }
  return inputs
}

function usageAndExit(code: number): never {
  console.error('Usage: tsx index.ts --input <file.json> [--input <file2.json> ...]')
  console.error('')
  console.error('Verifies that expected addresses are correctly enforced on-chain.')
  console.error('Each input file specifies a token, policy type, and list of addresses to check.')
  process.exit(code)
}

async function verifyPolicy(input: PolicyInput): Promise<{ passed: number; failed: number; mismatches: string[] }> {
  const chain = defineChain({
    id: input.chain_id,
    name: `chain-${input.chain_id}`,
    nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [input.rpc_url] } },
  })

  const client = createPublicClient({ chain, transport: http(input.rpc_url) }) as PublicClient

  const reportedChainId = await client.getChainId()
  if (reportedChainId !== input.chain_id) {
    throw new Error(`Chain mismatch: RPC reports ${reportedChainId}, expected ${input.chain_id}`)
  }

  const token = getAddress(input.token) as Address
  const authRegistry = getAddress(input.auth_registry) as Address

  const [symbol, name] = await Promise.all([
    client.readContract({ address: token, abi: tokenAbi, functionName: 'symbol' }),
    client.readContract({ address: token, abi: tokenAbi, functionName: 'name' }),
  ])

  const policyId = await (input.policy_type === 'transfer'
    ? client.readContract({ address: token, abi: tokenAbi, functionName: 'getTransferPolicyId' })
    : client.readContract({ address: token, abi: tokenAbi, functionName: 'getMintRecipientPolicyId' }))

  const [policyTypeRaw, admin] = (await client.readContract({
    address: authRegistry,
    abi: registryAbi,
    functionName: 'policyData',
    args: [policyId],
  })) as readonly [number, Address, bigint, boolean]

  const policyTypeName = policyTypeRaw === 0 ? 'WHITELIST' : 'BLACKLIST'

  console.log('')
  console.log(`━━━ ${input.name} ━━━`)
  console.log(`Token:    ${token} (${symbol} / ${name})`)
  console.log(`Chain:    ${input.chain_id}`)
  console.log(`Policy:   ${input.policy_type} → ID ${policyId} (${policyTypeName})`)
  console.log(`Admin:    ${admin}`)
  console.log('')

  const addresses = input.expected_addresses.map((a) => getAddress(a) as Address)
  console.log(`Checking ${addresses.length} addresses...`)

  let passed = 0
  let failed = 0
  const mismatches: string[] = []

  // Batch in groups of 20 for concurrency
  const batchSize = 20
  for (let i = 0; i < addresses.length; i += batchSize) {
    const batch = addresses.slice(i, i + batchSize)
    const results = await Promise.all(
      batch.map((addr) =>
        client.readContract({
          address: authRegistry,
          abi: registryAbi,
          functionName: 'isAuthorized',
          args: [policyId, addr],
        })
      )
    )

    for (let j = 0; j < batch.length; j++) {
      const addr = batch[j]
      const isAuthorized = results[j] as boolean

      if (policyTypeName === 'WHITELIST') {
        if (isAuthorized) {
          console.log(`  ✓ ${addr} authorized`)
          passed++
        } else {
          console.log(`  ✗ ${addr} NOT authorized (expected authorized)`)
          mismatches.push(addr)
          failed++
        }
      } else {
        // BLACKLIST: expected addresses should be blocked (isAuthorized = false)
        if (!isAuthorized) {
          console.log(`  ✓ ${addr} blocked`)
          passed++
        } else {
          console.log(`  ✗ ${addr} NOT blocked (expected blocked)`)
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

  return { passed, failed, mismatches }
}

async function main() {
  const inputFiles = parseArgs(process.argv.slice(2))
  let totalPassed = 0
  let totalFailed = 0
  const allMismatches: { name: string; mismatches: string[] }[] = []

  for (const file of inputFiles) {
    const raw = readFileSync(file, 'utf-8')
    const input: PolicyInput = JSON.parse(raw)
    const result = await verifyPolicy(input)
    totalPassed += result.passed
    totalFailed += result.failed
    if (result.mismatches.length > 0) {
      allMismatches.push({ name: input.name, mismatches: result.mismatches })
    }
  }

  if (inputFiles.length > 1) {
    console.log('')
    console.log('━━━ Summary ━━━')
    console.log(`Total: ${totalPassed + totalFailed} checks, ${totalPassed} passed, ${totalFailed} failed`)
  }

  if (allMismatches.length > 0) {
    console.log('')
    console.log('Mismatches:')
    for (const { name, mismatches } of allMismatches) {
      console.log(`  ${name}:`)
      for (const addr of mismatches) {
        console.log(`    ${addr}`)
      }
    }
    process.exit(1)
  }
}

main().catch((err) => {
  console.error('Error:', err.message ?? err)
  process.exit(1)
})
