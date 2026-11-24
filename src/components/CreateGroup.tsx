import { useMemo, useState } from 'react'
import { useAccount, useReadContracts } from 'wagmi'
import { isAddress, parseEventLogs, type Address } from 'viem'
import { ArrowLeft, CalendarClock, Coins, Info, Lock, Users, Zap } from 'lucide-react'
import { groupFactoryAbi } from '@/abi/groupFactory'
import { CHAIN_ID, FACTORY, fmt, parseInput } from '@/lib/rosca'
import { useTx } from '@/lib/tx'
import { useNow } from '@/hooks/useNow'
import { Avatar, Button, Callout, Card, Field, SectionTitle, Stat } from '@/components/ui'
import { CircleViz } from '@/components/CircleViz'

const toLocalInput = (ms: number) => {
  const d = new Date(ms - new Date().getTimezoneOffset() * 60_000)
  return d.toISOString().slice(0, 16)
}
const HOUR = 3_600_000

export function CreateGroup({ onBack, onCreated }: { onBack: () => void; onCreated: (a: Address) => void }) {
  const { address } = useAccount()
  const tx = useTx()
  const nowSec = useNow()
  const [n, setN] = useState(4)
  const [c, setC] = useState('10')
  const [phi, setPhi] = useState('50')
  const [d, setD] = useState('10')
  const [rho, setRho] = useState('0')
  const [start, setStart] = useState(() => toLocalInput(Date.now() + 3 * HOUR))
  const [deadline, setDeadline] = useState(() => toLocalInput(Date.now() + 2 * HOUR))
  const [periodH, setPeriodH] = useState('24')
  const [graceH, setGraceH] = useState('24')
  const [cureH, setCureH] = useState('24')
  const [members, setMembers] = useState<string[]>([])

  const { data: floors } = useReadContracts({
    contracts: [
      { address: FACTORY, abi: groupFactoryAbi, functionName: 'minC', chainId: CHAIN_ID },
      { address: FACTORY, abi: groupFactoryAbi, functionName: 'maxC', chainId: CHAIN_ID },
      { address: FACTORY, abi: groupFactoryAbi, functionName: 'minPhiBps', chainId: CHAIN_ID },
      { address: FACTORY, abi: groupFactoryAbi, functionName: 'minDepositBps', chainId: CHAIN_ID },
      { address: FACTORY, abi: groupFactoryAbi, functionName: 'maxDuration', chainId: CHAIN_ID },
    ] as const,
  })
  const minC = floors?.[0]?.result
  const maxC = floors?.[1]?.result
  const minPhiBps = floors?.[2]?.result
  const minDepositBps = floors?.[3]?.result
  const maxDuration = floors?.[4]?.result

  const roster = useMemo(() => Array.from({ length: n }, (_, i) => members[i] ?? ''), [n, members])

  const parsed = useMemo(() => {
    const cRaw = parseInput(c)
    const dRaw = parseInput(d)
    const rhoRaw = parseInput(rho || '0')
    const phiBps = Math.round(Number(phi) * 100)
    const startSec = Math.floor(new Date(start).getTime() / 1000)
    const deadlineSec = Math.floor(new Date(deadline).getTime() / 1000)
    return { cRaw, dRaw, rhoRaw, phiBps, startSec, deadlineSec, period: Math.round(Number(periodH) * 3600), grace: Math.round(Number(graceH) * 3600), cure: Math.round(Number(cureH) * 3600) }
  }, [c, d, rho, phi, start, deadline, periodH, graceH, cureH])

  const errors: string[] = []
  if (parsed.cRaw === undefined || parsed.cRaw <= 0n) errors.push('Enter a valid installment amount.')
  else if (minC !== undefined && maxC !== undefined && (parsed.cRaw < minC || parsed.cRaw > maxC)) errors.push(`The installment must be between ${fmt(minC)} and ${fmt(maxC)} USDC.`)
  if (parsed.rhoRaw === undefined) errors.push('Enter a valid reserve amount.')
  else if (parsed.cRaw !== undefined && parsed.rhoRaw > parsed.cRaw / 10n) errors.push('The reserve per round cannot exceed 10% of the installment.')
  if (parsed.dRaw === undefined) errors.push('Enter a valid deposit.')
  else if (parsed.cRaw !== undefined && parsed.rhoRaw !== undefined) {
    if (parsed.dRaw < parsed.cRaw + parsed.rhoRaw) errors.push('The deposit must cover one full installment (installment plus reserve).')
    if (minDepositBps !== undefined && parsed.dRaw * 10_000n < parsed.cRaw * BigInt(minDepositBps)) errors.push('The deposit is below the factory minimum.')
  }
  if (!Number.isFinite(parsed.phiBps) || (minPhiBps !== undefined && parsed.phiBps < minPhiBps) || parsed.phiBps > 10_000)
    errors.push(`Holdback must be between ${minPhiBps !== undefined ? minPhiBps / 100 : 30}% and 100%.`)
  if (parsed.period < 3600) errors.push('Rounds must be at least 1 hour apart.')
  if (parsed.grace < 3600 || parsed.grace > 14 * 86400) errors.push('The grace period must be between 1 hour and 14 days.')
  if (parsed.cure < 3600 || parsed.cure > 7 * 86400) errors.push('The cure window must be between 1 hour and 7 days.')
  if (maxDuration !== undefined && BigInt(n) * BigInt(parsed.period) > maxDuration) errors.push('The total duration exceeds the factory limit.')
  if (!(parsed.startSec > nowSec)) errors.push('The start time must be in the future.')
  if (!(parsed.deadlineSec > nowSec) || parsed.deadlineSec > parsed.startSec) errors.push('The join deadline must be in the future and no later than the start time.')
  const bad = roster.findIndex((m) => !isAddress(m))
  if (bad >= 0) errors.push(`The address for position ${bad + 1} is missing or invalid.`)
  else if (new Set(roster.map((m) => m.toLowerCase())).size !== roster.length) errors.push('Each member address must be unique.')

  const valid = errors.length === 0 && parsed.cRaw !== undefined && parsed.dRaw !== undefined && parsed.rhoRaw !== undefined
  const pot = parsed.cRaw !== undefined ? parsed.cRaw * BigInt(n) : undefined
  const hbFirst = parsed.cRaw !== undefined ? (BigInt(parsed.phiBps) * parsed.cRaw * BigInt(n - 1) + 9_999n) / 10_000n : undefined

  const quickTest = () => {
    setPeriodH('1')
    setGraceH('1')
    setCureH('1')
    setDeadline(toLocalInput(Date.now() + HOUR))
    setStart(toLocalInput(Date.now() + 2 * HOUR))
  }

  const submit = async () => {
    if (!valid || parsed.cRaw === undefined || parsed.dRaw === undefined || parsed.rhoRaw === undefined) return
    const receipt = await tx.run(
      {
        address: FACTORY,
        abi: groupFactoryAbi,
        functionName: 'createGroup',
        args: [
          {
            n,
            c: parsed.cRaw,
            phiBps: parsed.phiBps,
            d: parsed.dRaw,
            rho: parsed.rhoRaw,
            startTime: BigInt(parsed.startSec),
            period: BigInt(parsed.period),
            grace: BigInt(parsed.grace),
            cure: BigInt(parsed.cure),
            acceptDeadline: BigInt(parsed.deadlineSec),
            useGate: false,
            minScoreMilli: 0,
            ungatedCap: 0n,
            members: roster as Address[],
          },
        ],
      },
      'Circle created',
    )
    if (!receipt) return
    const created = parseEventLogs({ abi: groupFactoryAbi, logs: receipt.logs, eventName: 'GroupCreated' })[0]?.args.group
    if (created) onCreated(created)
    else onBack()
  }

  return (
    <div className="space-y-5">
      <button onClick={onBack} className="flex min-h-11 items-center gap-1.5 text-sm font-semibold" style={{ color: 'var(--accent-hover)' }}>
        <ArrowLeft className="size-4" aria-hidden /> Back
      </button>

      <Card spectral>
        <h1 className="display text-3xl font-bold">Create a circle</h1>
        <p className="mt-2 max-w-lg text-pretty text-sm leading-relaxed" style={{ color: 'var(--muted)' }}>
          Every rule is locked in the contract when you create it. The creator has no special power over members&apos; money, and the order cannot be changed afterwards.
        </p>
      </Card>

      <Card>
        <SectionTitle icon={<Coins className="size-4" aria-hidden />} title="1. Size and installment" />
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Members" type="number" min={4} max={10} value={n} onChange={(e) => setN(Math.min(10, Math.max(4, Number(e.target.value) || 4)))} hint="4 to 10. One round per member." />
          <Field label="Installment per round" suffix="USDC" inputMode="decimal" value={c} onChange={(e) => setC(e.target.value)} hint="What each member pays every round." />
        </div>
      </Card>

      <Card>
        <SectionTitle icon={<Lock className="size-4" aria-hidden />} title="2. Collateral" hint="Protects members who are still waiting for their turn." />
        <div className="grid gap-4 sm:grid-cols-3">
          <Field label="Holdback from the pot" suffix="%" inputMode="decimal" value={phi} onChange={(e) => setPhi(e.target.value)} hint="Kept back when you receive the pot, then released round by round as you keep paying." />
          <Field label="Deposit per member" suffix="USDC" inputMode="decimal" value={d} onChange={(e) => setD(e.target.value)} hint="Returned at the end if you never default." />
          <Field label="Reserve per round" suffix="USDC" inputMode="decimal" value={rho} onChange={(e) => setRho(e.target.value)} hint="Optional shared buffer. Unused amounts are refunded." />
        </div>
      </Card>

      <Card>
        <SectionTitle
          icon={<CalendarClock className="size-4" aria-hidden />}
          title="3. Schedule"
          action={
            <Button variant="ghost" small onClick={quickTest}>
              <Zap className="size-3.5" aria-hidden /> Quick test (1h rounds)
            </Button>
          }
        />
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Time between rounds" suffix="hours" inputMode="decimal" value={periodH} onChange={(e) => setPeriodH(e.target.value)} />
          <Field label="Grace period" suffix="hours" inputMode="decimal" value={graceH} onChange={(e) => setGraceH(e.target.value)} hint="Time after a due date before the pot is paid out." />
          <Field label="Cure window" suffix="hours" inputMode="decimal" value={cureH} onChange={(e) => setCureH(e.target.value)} hint="After this, a late deposit can cover the installment, or the member defaults." />
          <span aria-hidden className="hidden sm:block" />
          <Field label="Join deadline" type="datetime-local" value={deadline} onChange={(e) => setDeadline(e.target.value)} />
          <Field label="First round starts" type="datetime-local" value={start} onChange={(e) => setStart(e.target.value)} />
        </div>
      </Card>

      <Card>
        <SectionTitle
          icon={<Users className="size-4" aria-hidden />}
          title="4. Members in payout order"
          hint="Position 1 takes the pot first. Each member must join from their own wallet and post the deposit."
        />
        <div className="grid items-start gap-6 sm:grid-cols-[1fr_200px]">
          <div className="space-y-3">
            {roster.map((m, i) => (
              <div key={i} className="flex items-end gap-2.5">
                <span className="mb-2 flex size-8 shrink-0 items-center justify-center">
                  {isAddress(m) ? (
                    <Avatar address={m} size={32} />
                  ) : (
                    <span className="display flex size-8 items-center justify-center rounded-full text-xs font-bold" style={{ background: 'var(--surface-muted)', color: 'var(--muted)' }}>
                      {i + 1}
                    </span>
                  )}
                </span>
                <Field
                  className="mono flex-1"
                  label={`Position ${i + 1}`}
                  placeholder="0x..."
                  value={m}
                  onChange={(e) => setMembers(roster.map((x, j) => (j === i ? e.target.value : x)))}
                  error={m && !isAddress(m) ? 'Not a valid address' : undefined}
                />
                {address && !m ? (
                  <Button variant="ghost" small className="mb-1.5" onClick={() => setMembers(roster.map((x, j) => (j === i ? address : x)))}>
                    Me
                  </Button>
                ) : null}
              </div>
            ))}
          </div>
          <div className="hidden sm:block">
            <CircleViz
              size={200}
              nodes={roster.map((m, i) => ({ label: String(i + 1), tone: isAddress(m) ? 'done' : 'upcoming' }))}
              decorative
            >
              <div className="text-[11px] font-semibold" style={{ color: 'var(--muted)' }}>
                {roster.filter((m) => isAddress(m)).length} of {n} set
              </div>
            </CircleViz>
          </div>
        </div>
      </Card>

      <Card strong>
        <SectionTitle icon={<Info className="size-4" aria-hidden />} title="Summary" />
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <Stat label="Pot per round" value={`${fmt(pot)} USDC`} />
          <Stat label="First holdback" value={`${fmt(hbFirst)} USDC`} sub="Withheld from position 1" />
          <Stat label="First cash out" value={`${pot !== undefined && hbFirst !== undefined ? fmt(pot - hbFirst) : '...'} USDC`} />
          <Stat label="Deposit to post" value={`${parsed.dRaw !== undefined ? fmt(parsed.dRaw) : '...'} USDC`} sub="Per member, to join" />
        </div>
        <div className="mt-4">
          <Callout icon={<Info className="size-4" aria-hidden />}>
            If a member defaults, the contract takes their collateral up to what they still owe. Whatever is left is a loss for members who have not yet received the pot. Principal is not guaranteed, and this version has no interest.
          </Callout>
        </div>
        {errors.length > 0 ? (
          <ul className="mt-4 list-disc space-y-1 pl-5 text-xs" style={{ color: 'var(--danger)' }}>
            {errors.map((e) => (
              <li key={e}>{e}</li>
            ))}
          </ul>
        ) : null}
        <div className="mt-5">
          <Button full disabled={!valid || !address} loading={tx.busy} onClick={() => void submit()}>
            {!address ? 'Connect your wallet first' : tx.phase === 'wallet' ? 'Confirm in your wallet...' : tx.phase === 'confirming' ? 'Confirming onchain...' : 'Create circle'}
          </Button>
        </div>
      </Card>
    </div>
  )
}
