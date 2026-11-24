import { arc, arcTestnet } from 'viem/chains'
import { isAddress, type Address } from 'viem'
import { getUsdc, buildAddressExplorerUrl, buildTxExplorerUrl } from '@/onchain-facts'
import { Amount, parseAmount, usdcDecimalsFor } from '@/onchain-money'

const rawEnv = import.meta.env
const env = (key: string): string | undefined => {
  const v: unknown = (rawEnv as Record<string, unknown>)[key]
  return typeof v === 'string' && v ? v : undefined
}

/** Which Arc network this build talks to. Defaults to testnet. */
export const IS_MAINNET = env('VITE_ROSCA_NETWORK') === 'mainnet'
export const CHAIN_ID = IS_MAINNET ? arc.id : arcTestnet.id
export const NETWORK_NAME = IS_MAINNET ? 'Arc' : 'Arc Testnet'

const pick = (testnet: string | undefined, mainnet: string | undefined) => (IS_MAINNET ? mainnet : testnet)
const factoryRaw = pick(env('VITE_ROSCA_FACTORY_ADDRESS'), env('VITE_ROSCA_MAINNET_FACTORY_ADDRESS'))
export const FACTORY = factoryRaw as Address
export const REGISTRY = pick(env('VITE_ROSCA_REGISTRY_ADDRESS'), env('VITE_ROSCA_MAINNET_REGISTRY_ADDRESS')) as Address
export const GATE = pick(env('VITE_ROSCA_GATE_ADDRESS'), env('VITE_ROSCA_MAINNET_GATE_ADDRESS')) as Address
export const ADMIN = pick(env('VITE_ROSCA_ADMIN_ADDRESS'), env('VITE_ROSCA_MAINNET_ADMIN_ADDRESS')) as Address

/** Set when the build cannot work, for example mainnet selected without a factory address. */
export const CONFIG_ERROR: string | undefined = !factoryRaw || !isAddress(factoryRaw)
  ? IS_MAINNET
    ? 'Mainnet is selected but VITE_ROSCA_MAINNET_FACTORY_ADDRESS is missing or invalid. Deploy the contracts yourself, then set the mainnet addresses in .env and rebuild.'
    : 'VITE_ROSCA_FACTORY_ADDRESS is missing or invalid.'
  : undefined

const usdcFact = getUsdc(CHAIN_ID)
if (!usdcFact) throw new Error('USDC is missing for ' + NETWORK_NAME + ' in onchain-facts')
export const USDC = usdcFact.address as Address
export const DECIMALS = usdcDecimalsFor(CHAIN_ID)

export const GROUP_STATE = ['Open for members', 'Locked, waiting to start', 'Active', 'Closed', 'Cancelled'] as const
export const MEMBER_STATUS = ['Not joined', 'Accepted', 'In good standing', 'Defaulted'] as const

export const STATE = { Recruiting: 0, Locked: 1, Active: 2, Closed: 3, Cancelled: 4 } as const
export const STATUS = { None: 0, Accepted: 1, Active: 2, Defaulted: 3 } as const

export const addressUrl = (a: string) => buildAddressExplorerUrl(CHAIN_ID, a)
export const txUrl = (h: string) => buildTxExplorerUrl(CHAIN_ID, h)

/** Format a raw 6-decimal USDC value with two fraction digits. */
export function fmt(raw: bigint | undefined, digits = 2): string {
  if (raw === undefined) return '...'
  return Amount.fromRaw(raw, DECIMALS).toFixed(digits)
}

/** Parse a user-typed USDC amount. Returns undefined for empty or invalid input. */
export function parseInput(value: string): bigint | undefined {
  if (!value.trim()) return undefined
  try {
    return parseAmount(CHAIN_ID, value.trim()).raw
  } catch {
    return undefined
  }
}

export const short = (a: string) => `${a.slice(0, 6)}...${a.slice(-4)}`

export function fmtDate(seconds: bigint | number): string {
  const d = new Date(Number(seconds) * 1000)
  return d.toLocaleString('en-US', { dateStyle: 'medium', timeStyle: 'short' })
}

export function fmtDuration(seconds: number): string {
  if (seconds % 86400 === 0) return `${seconds / 86400} ${seconds === 86400 ? 'day' : 'days'}`
  if (seconds % 3600 === 0) return `${seconds / 3600} ${seconds === 3600 ? 'hour' : 'hours'}`
  return `${seconds} sec`
}

export const emptyAttestation = { scoreMilli: 0, expiresAt: 0n, nonce: 0n, sig: '0x' } as const

export function parseError(error: unknown): string | undefined {
  const err = error as { message?: string; shortMessage?: string; code?: number; name?: string } | undefined
  const msg = `${err?.shortMessage ?? ''} ${err?.message ?? ''}`.toLowerCase()
  if (err?.code === 4001 || msg.includes('user rejected') || msg.includes('user denied')) return undefined
  if (msg.includes('insufficient funds') || msg.includes('exceeds balance')) return 'Not enough USDC for this transaction.'
  const name = /error:?\s*([A-Za-z]+)\(/.exec(err?.message ?? '')?.[1]
  if (msg.includes('reverted')) return name ? `The contract rejected this transaction (${name}).` : 'The contract rejected this transaction.'
  if (msg.includes('network') || msg.includes('timeout')) return 'Network issue. Please try again.'
  return 'Something went wrong. Please try again.'
}
