import { useMemo } from 'react'
import { useAccount, useReadContract, useReadContracts } from 'wagmi'
import { erc20Abi, type Address } from 'viem'
import { roscaGroupAbi } from '@/abi/roscaGroup'
import { CHAIN_ID, USDC } from '@/lib/rosca'

const POLL = 8_000

export interface MemberRow {
  slot: number
  wallet: Address
  status: number
  deposit: bigint
  holdback: bigint
  claimable: bigint
  rhoPaidTotal: bigint
  depositUses: number
}

export interface RoundRow {
  t: number
  due: bigint
  recipient: Address
  settled: boolean
  skipped: boolean
  ready: boolean
  principalPaid: readonly bigint[]
  reservePaid: readonly bigint[]
}

/** Reads one group's full state from Arc Testnet and polls for changes. */
export function useGroupData(group: Address) {
  const { address } = useAccount()
  const base = { address: group, abi: roscaGroupAbi, chainId: CHAIN_ID } as const

  const head = useReadContracts({
    contracts: [
      { ...base, functionName: 'getTerms' },
      { ...base, functionName: 'state' },
      { ...base, functionName: 'termsHash' },
      { ...base, functionName: 'nextRound' },
      { ...base, functionName: 'reserve' },
      { ...base, functionName: 'coveragePool' },
      { ...base, functionName: 'acceptedCount' },
      { ...base, functionName: 'creator' },
    ] as const,
    query: { refetchInterval: POLL },
  })

  const terms = head.data?.[0]?.status === 'success' ? head.data[0].result : undefined
  const n = terms?.n ?? 0

  const detail = useReadContracts({
    contracts: Array.from({ length: n }, (_, i) => i + 1).flatMap(
      (k) =>
        [
          { ...base, functionName: 'memberInfo', args: [k] },
          { ...base, functionName: 'roundInfo', args: [k] },
        ] as const,
    ),
    query: { enabled: n > 0, refetchInterval: POLL },
  })

  const me = useReadContract({
    ...base,
    functionName: 'claimable',
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address), refetchInterval: POLL },
  })

  const allowance = useReadContract({
    address: USDC,
    abi: erc20Abi,
    functionName: 'allowance',
    args: address ? [address, group] : undefined,
    chainId: CHAIN_ID,
    query: { enabled: Boolean(address), refetchInterval: POLL },
  })

  const members: MemberRow[] = useMemo(() => {
    const rows: MemberRow[] = []
    for (let i = 0; i < n; i++) {
      const r = detail.data?.[i * 2]
      if (r?.status !== 'success' || !('wallet' in r.result)) continue
      const v = r.result
      rows.push({
        slot: i + 1,
        wallet: v.wallet,
        status: Number(v.status),
        deposit: v.deposit,
        holdback: v.holdback,
        claimable: v.claimable,
        rhoPaidTotal: v.rhoPaidTotal,
        depositUses: Number(v.depositUses),
      })
    }
    return rows
  }, [detail.data, n])

  const rounds: RoundRow[] = useMemo(() => {
    const rows: RoundRow[] = []
    for (let i = 0; i < n; i++) {
      const r = detail.data?.[i * 2 + 1]
      if (r?.status !== 'success' || !('due' in r.result)) continue
      const v = r.result
      rows.push({
        t: i + 1,
        due: v.due,
        recipient: v.recipient,
        settled: v.settled,
        skipped: v.skipped,
        ready: v.ready,
        principalPaid: v.principalPaid,
        reservePaid: v.reservePaid,
      })
    }
    return rows
  }, [detail.data, n])

  const get = <T,>(i: number): T | undefined => {
    const r = head.data?.[i]
    return r?.status === 'success' ? (r.result as T) : undefined
  }

  return {
    loading: head.isLoading,
    failed: !head.isLoading && !terms,
    terms,
    state: get<number>(1),
    termsHash: get<`0x${string}`>(2),
    nextRound: get<number>(3),
    reserve: get<bigint>(4),
    coveragePool: get<bigint>(5),
    acceptedCount: get<number>(6),
    creator: get<Address>(7),
    members,
    rounds,
    myClaimable: me.data,
    allowance: allowance.data,
    mySlot: address && terms ? terms.members.findIndex((m) => m.toLowerCase() === address.toLowerCase()) + 1 : 0,
  }
}
