import { useMemo, useState } from 'react'
import { useAccount, useReadContract, useReadContracts } from 'wagmi'
import { isAddress, type Address } from 'viem'
import { ArrowRight, ChevronRight, CircleDollarSign, Plus, Search, ShieldCheck, Users, Vault } from 'lucide-react'
import { groupFactoryAbi } from '@/abi/groupFactory'
import { roscaGroupAbi } from '@/abi/roscaGroup'
import { CHAIN_ID, FACTORY, GROUP_STATE, IS_MAINNET, fmt, short } from '@/lib/rosca'
import { Avatar, Badge, Button, Callout, Card, Field, SectionTitle, Skeleton } from '@/components/ui'
import { CircleViz, type CircleNode } from '@/components/CircleViz'

const MAX_SCAN = 40n

const heroNodes: CircleNode[] = [
  { label: '1', tone: 'done' },
  { label: '2', tone: 'done' },
  { label: '3', tone: 'current' },
  { label: '4', tone: 'upcoming' },
  { label: '5', tone: 'upcoming' },
  { label: '6', tone: 'upcoming' },
]

const steps = [
  { icon: Users, title: 'Agree on the order', body: 'A small group fixes who takes the pot in which round. The rules are locked in the contract when the circle is created.' },
  { icon: CircleDollarSign, title: 'Pay each round', body: 'Everyone sends the same USDC installment each round. One member receives the pot, in turn.' },
  { icon: ShieldCheck, title: 'Collateral protects the group', body: 'Part of each pot is held back and every member posts a deposit. If someone defaults, their collateral covers what it can.' },
]

export function GroupList({ onOpen, onCreate }: { onOpen: (a: Address) => void; onCreate: () => void }) {
  const { address } = useAccount()
  const [lookup, setLookup] = useState('')

  const { data: count, isLoading: countLoading } = useReadContract({
    address: FACTORY,
    abi: groupFactoryAbi,
    functionName: 'groupCount',
    chainId: CHAIN_ID,
    query: { refetchInterval: 20_000 },
  })

  const indexes = useMemo(() => {
    if (count === undefined) return []
    const first = count > MAX_SCAN ? count - MAX_SCAN : 0n
    const out: bigint[] = []
    for (let i = count; i > first; i--) out.push(i - 1n)
    return out
  }, [count])

  const { data: addrResults } = useReadContracts({
    contracts: indexes.map((i) => ({ address: FACTORY, abi: groupFactoryAbi, functionName: 'groups', args: [i], chainId: CHAIN_ID }) as const),
    query: { enabled: indexes.length > 0 },
  })

  const groups = useMemo(
    () => (addrResults ?? []).flatMap((r) => (r.status === 'success' && typeof r.result === 'string' ? [r.result] : [])),
    [addrResults],
  )

  const { data: details, isLoading: detailsLoading } = useReadContracts({
    contracts: groups.flatMap(
      (g) =>
        [
          { address: g, abi: roscaGroupAbi, functionName: 'getTerms', chainId: CHAIN_ID },
          { address: g, abi: roscaGroupAbi, functionName: 'state', chainId: CHAIN_ID },
        ] as const,
    ),
    query: { enabled: groups.length > 0, refetchInterval: 20_000 },
  })

  const rows = groups.map((g, i) => {
    const terms = details?.[i * 2]
    const state = details?.[i * 2 + 1]
    if (terms?.status !== 'success' || state?.status !== 'success') return undefined
    if (typeof terms.result !== 'object' || typeof state.result !== 'number') return undefined
    const t = terms.result
    const slot = address ? t.members.findIndex((m) => m.toLowerCase() === address.toLowerCase()) + 1 : 0
    return { group: g, n: t.n, c: t.c, state: state.result, slot, members: t.members }
  })
  const mine = rows.flatMap((r) => (r && r.slot > 0 ? [r] : []))
  const lookupValid = isAddress(lookup.trim())
  const loading = countLoading || detailsLoading

  return (
    <div className="space-y-5">
      <Card spectral className="!p-6 sm:!p-8">
        <div className="grid items-center gap-6 sm:grid-cols-[1.3fr_1fr]">
          <div>
            <div className="label-caps">Rotating savings on USDC</div>
            <h1 className="display mt-3 text-balance text-4xl font-bold leading-[1.05] sm:text-5xl">Save together. Take turns.</h1>
            <p className="mt-4 max-w-md text-pretty text-sm leading-relaxed" style={{ color: 'var(--muted)' }}>
              A small circle of people pays in every round and one member takes the pot. Collateral is held on chain, and the rules are fixed before anyone pays.
            </p>
            <div className="mt-6 flex flex-wrap items-center gap-3">
              <Button onClick={onCreate}>
                <Plus className="size-4" aria-hidden /> Create a circle
              </Button>
              <a href="#how" className="inline-flex min-h-11 items-center gap-1 text-sm font-semibold" style={{ color: 'var(--accent-hover)' }}>
                How it works <ArrowRight className="size-4" aria-hidden />
              </a>
            </div>
          </div>
          <div className="order-first sm:order-last">
            <CircleViz nodes={heroNodes} size={220} decorative>
              <div>
                <Vault className="mx-auto size-6" style={{ color: 'var(--accent)' }} aria-hidden />
                <div className="display mt-1 text-sm font-bold">One pot per round</div>
              </div>
            </CircleViz>
          </div>
        </div>
      </Card>

      <Card>
        <SectionTitle
          icon={<Users className="size-4" aria-hidden />}
          title="Your circles"
          action={address ? <Badge>{short(address)}</Badge> : undefined}
        />
        {!address ? (
          <p className="text-sm" style={{ color: 'var(--muted)' }}>
            Connect your wallet to see the circles you belong to.
          </p>
        ) : loading ? (
          <div className="space-y-2">
            <Skeleton className="h-16" />
            <Skeleton className="h-16" />
          </div>
        ) : mine.length === 0 ? (
          <div className="rounded-2xl p-5 text-center" style={{ background: 'var(--surface-muted)' }}>
            <p className="text-sm font-semibold">No circles yet</p>
            <p className="mx-auto mt-1 max-w-xs text-pretty text-xs" style={{ color: 'var(--muted)' }}>
              Checked the latest {String(Math.min(Number(count ?? 0n), Number(MAX_SCAN)))} of {String(count ?? 0n)} circles for this wallet. Create one, or open a circle you were invited to.
            </p>
            <Button className="mt-4" small onClick={onCreate}>
              <Plus className="size-3.5" aria-hidden /> Create a circle
            </Button>
          </div>
        ) : (
          <ul className="space-y-2">
            {mine.map((r) => (
              <li key={r.group}>
                <button
                  onClick={() => onOpen(r.group)}
                  className="lift flex min-h-[68px] w-full items-center gap-3 rounded-2xl px-4 py-3 text-left"
                  style={{ background: 'var(--surface-strong)', border: '1px solid var(--border)' }}
                >
                  <span className="flex -space-x-2">
                    {r.members.slice(0, 3).map((m) => (
                      <Avatar key={m} address={m} size={30} />
                    ))}
                  </span>
                  <span className="min-w-0 flex-1">
                    <span className="block truncate text-sm font-semibold tabular-nums">
                      {r.n} members, {fmt(r.c)} USDC per round
                    </span>
                    <span className="mono block truncate text-xs" style={{ color: 'var(--muted)' }}>
                      {short(r.group)} · your position {r.slot}
                    </span>
                  </span>
                  <Badge tone={r.state === 2 ? 'success' : r.state === 4 ? 'danger' : 'neutral'}>{GROUP_STATE[r.state] ?? '-'}</Badge>
                  <ChevronRight className="size-4 shrink-0" style={{ color: 'var(--subtle)' }} aria-hidden />
                </button>
              </li>
            ))}
          </ul>
        )}
      </Card>

      <Card>
        <SectionTitle icon={<Search className="size-4" aria-hidden />} title="Open a circle" hint="Paste the contract address you were sent." />
        <div className="flex items-end gap-2">
          <Field
            className="flex-1"
            label="Circle address"
            placeholder="0x..."
            value={lookup}
            onChange={(e) => setLookup(e.target.value)}
            error={lookup && !lookupValid ? 'Not a valid address' : undefined}
          />
          <Button variant="ghost" disabled={!lookupValid} onClick={() => onOpen(lookup.trim() as Address)} aria-label="Open circle">
            Open
          </Button>
        </div>
      </Card>

      <section id="how" className="scroll-mt-6">
        <h2 className="display mb-3 px-1 text-xl font-semibold">How it works</h2>
        <div className="grid gap-3 sm:grid-cols-3">
          {steps.map((s, i) => (
            <Card key={s.title} className="!p-5">
              <div className="flex items-center gap-2.5">
                <span className="flex size-9 items-center justify-center rounded-xl" style={{ background: 'var(--accent)', color: '#fff' }}>
                  <s.icon className="size-4.5" aria-hidden />
                </span>
                <span className="label-caps">Step {i + 1}</span>
              </div>
              <h3 className="display mt-3 text-base font-semibold">{s.title}</h3>
              <p className="mt-1.5 text-pretty text-xs leading-relaxed" style={{ color: 'var(--muted)' }}>
                {s.body}
              </p>
            </Card>
          ))}
        </div>
      </section>

      <Callout icon={<ShieldCheck className="size-4" aria-hidden />}>
        {IS_MAINNET ? 'This circle uses real USDC on Arc mainnet.' : 'This is a test version on Arc Testnet with no real value.'} Nobody guarantees principal: if a member defaults, the loss left after their collateral is borne by members who have not yet received the pot.
      </Callout>
    </div>
  )
}
