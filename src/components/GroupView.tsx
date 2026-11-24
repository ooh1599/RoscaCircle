import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import { erc20Abi, type Address } from 'viem'
import { AlertTriangle, ArrowLeft, Copy, ExternalLink, UserRound } from 'lucide-react'
import { toast } from 'sonner'
import { roscaGroupAbi } from '@/abi/roscaGroup'
import { useGroupData } from '@/hooks/useGroupData'
import { GROUP_STATE, IS_MAINNET, NETWORK_NAME, STATE, STATUS, USDC, addressUrl, emptyAttestation, fmt, fmtDate, short, txUrl } from '@/lib/rosca'
import { useTx } from '@/lib/tx'
import { buildShareLink } from '@/lib/share'
import { Avatar, Badge, Button, Callout, Card, ProgressBar, SectionTitle, Skeleton, Stat } from '@/components/ui'
import { CircleViz, type CircleNode } from '@/components/CircleViz'
import { MembersTable, RoundsList, RulesCard } from '@/components/GroupParts'

export function GroupView({ group, onBack }: { group: Address; onBack: () => void }) {
  const { address } = useAccount()
  const data = useGroupData(group)
  const tx = useTx()
  const [nowSec, setNowSec] = useState(() => Math.floor(Date.now() / 1000))
  const [shareUrl, setShareUrl] = useState<string | undefined>()

  useEffect(() => {
    const id = setInterval(() => setNowSec(Math.floor(Date.now() / 1000)), 15_000)
    return () => clearInterval(id)
  }, [])
  useEffect(() => {
    let live = true
    void buildShareLink(`/?group=${group}`).then((u) => live && setShareUrl(u))
    return () => {
      live = false
    }
  }, [group])

  const { terms, state, members, rounds, mySlot, allowance, myClaimable } = data

  if (data.loading) {
    return (
      <div className="space-y-4">
        <BackButton onBack={onBack} />
        <Skeleton className="h-64" />
        <Skeleton className="h-40" />
      </div>
    )
  }
  if (data.failed || !terms || state === undefined) {
    return (
      <div className="space-y-3">
        <BackButton onBack={onBack} />
        <Card>
          <p className="flex items-center gap-2 text-sm" style={{ color: 'var(--danger)' }}>
            <AlertTriangle className="size-4" aria-hidden /> Could not read this circle. Check that the address is a circle contract on {NETWORK_NAME}.
          </p>
        </Card>
      </div>
    )
  }

  const inst = terms.c + terms.rho
  const me = members.find((m) => m.slot === mySlot)
  const write = (functionName: string, args: readonly unknown[], ok: string) =>
    tx.run({ address: group, abi: roscaGroupAbi, functionName, args }, ok)

  const ensureAllowance = async (amount: bigint): Promise<boolean> => {
    if ((allowance ?? 0n) >= amount) return true
    const r = await tx.run({ address: USDC, abi: erc20Abi, functionName: 'approve', args: [group, amount] }, 'USDC spending approved for this circle')
    return Boolean(r)
  }

  const join = async () => {
    if (!(await ensureAllowance(terms.d))) return
    await write('accept', [emptyAttestation], 'You joined the circle')
  }
  const payRound = async (t: number, remaining: bigint) => {
    if (!address || !(await ensureAllowance(remaining))) return
    await write('pay', [t, address, remaining], `Round ${t} paid`)
  }
  const topUp = async () => {
    if (!me) return
    const need = terms.d - me.deposit
    if (!(await ensureAllowance(need))) return
    await write('topUpDeposit', [need], 'Deposit topped up')
  }

  const isRecruiting = state === STATE.Recruiting
  const isActive = state === STATE.Active
  const deadlinePassed = nowSec > Number(terms.acceptDeadline)
  const canJoin = isRecruiting && mySlot > 0 && me?.status === STATUS.None && !deadlinePassed
  const joined = mySlot > 0 && me !== undefined && me.status !== STATUS.None
  const canWithdraw = (state === STATE.Recruiting || state === STATE.Locked) && me?.status === STATUS.Accepted
  const canCancel = (isRecruiting && deadlinePassed) || (state === STATE.Locked && nowSec >= Number(terms.startTime) + Number(terms.period))
  const needsSync = (state === STATE.Locked && nowSec >= Number(terms.startTime)) || (isActive && rounds.some((r) => !r.settled && !r.skipped && r.ready))
  const canFinalize = isActive && (data.nextRound ?? 0) > terms.n

  const nextDue =
    isActive && mySlot > 0
      ? rounds.find((r) => {
          if (r.t === mySlot || r.skipped || nowSec < Number(r.due)) return false
          const paid = (r.principalPaid[mySlot - 1] ?? 0n) + (r.reservePaid[mySlot - 1] ?? 0n)
          return paid < inst
        })
      : undefined
  const nextDueRemaining = nextDue ? inst - ((nextDue.principalPaid[mySlot - 1] ?? 0n) + (nextDue.reservePaid[mySlot - 1] ?? 0n)) : 0n

  const late = isActive
    ? rounds.flatMap((r) =>
        nowSec < Number(r.due) + Number(terms.grace) + Number(terms.cure) || r.skipped
          ? []
          : members.flatMap((m) => {
              const paid = (r.principalPaid[m.slot - 1] ?? 0n) + (r.reservePaid[m.slot - 1] ?? 0n)
              return m.slot !== r.t && m.status === STATUS.Active && paid < inst ? [{ t: r.t, member: m, missing: inst - paid }] : []
            }),
      )
    : []

  const primary = (() => {
    if (!address) return { label: 'Connect your wallet (top right) to take part', run: undefined as (() => void) | undefined }
    if ((myClaimable ?? 0n) > 0n) return { label: `Claim ${fmt(myClaimable)} USDC to your wallet`, run: () => void write('claim', [], 'Funds claimed') }
    if (canJoin) return { label: `Join and post ${fmt(terms.d)} USDC deposit`, run: () => void join() }
    if (nextDue) return { label: `Pay round ${nextDue.t}: ${fmt(nextDueRemaining)} USDC`, run: () => void payRound(nextDue.t, nextDueRemaining) }
    if (canFinalize) return { label: 'Close the circle and return collateral', run: () => void write('finalize', [], 'Circle closed') }
    return { label: undefined, run: undefined }
  })()

  const copyLink = async () => {
    if (!shareUrl) return
    try {
      await navigator.clipboard.writeText(shareUrl)
      toast.success('Link copied')
    } catch {
      toast.error('Could not copy the link')
    }
  }

  const round = Math.min(data.nextRound ?? 1, terms.n)
  const settledCount = rounds.filter((r) => r.settled || r.skipped).length
  const nodes: CircleNode[] = Array.from({ length: terms.n }, (_, i) => {
    const slot = i + 1
    const m = members.find((x) => x.slot === slot)
    const r = rounds.find((x) => x.t === slot)
    if (m?.status === STATUS.Defaulted) return { label: String(slot), tone: 'bad' }
    if (r?.skipped) return { label: String(slot), tone: 'skipped' }
    if (isRecruiting || state === STATE.Locked) return { label: String(slot), tone: m && m.status !== STATUS.None ? 'done' : 'upcoming' }
    if (r?.settled) return { label: String(slot), tone: 'done' }
    if (isActive && slot === round) return { label: String(slot), tone: 'current' }
    return { label: String(slot), tone: 'upcoming' }
  })

  return (
    <div className="space-y-5">
      <BackButton onBack={onBack} />

      <Card spectral className="!p-6 sm:!p-8">
        <div className="grid items-center gap-6 sm:grid-cols-[1.2fr_1fr]">
          <div>
            <div className="flex flex-wrap items-center gap-2">
              <Badge tone={isActive ? 'success' : state === STATE.Cancelled ? 'danger' : 'neutral'}>{GROUP_STATE[state] ?? '-'}</Badge>
              <span className="label-caps">Circle of {terms.n}</span>
            </div>
            <div className="mt-4 flex items-baseline gap-2">
              <span className="display text-5xl font-bold tabular-nums">{fmt(terms.c * BigInt(terms.n))}</span>
              <span className="text-base font-medium" style={{ color: 'var(--subtle)' }}>
                USDC pot
              </span>
            </div>
            <p className="mt-1.5 text-sm tabular-nums" style={{ color: 'var(--muted)' }}>
              {fmt(terms.c)} USDC per member, each round
            </p>
            <div className="mt-5 max-w-xs">
              <ProgressBar
                value={isActive || state === STATE.Closed ? settledCount : (data.acceptedCount ?? 0)}
                max={terms.n}
                label={isActive ? 'Rounds completed' : 'Members joined'}
              />
              <p className="mt-1.5 text-xs tabular-nums" style={{ color: 'var(--muted)' }}>
                {isActive
                  ? `Round ${round} of ${terms.n}`
                  : isRecruiting
                    ? `${data.acceptedCount ?? 0} of ${terms.n} members joined`
                    : state === STATE.Locked
                      ? `Starts ${fmtDate(terms.startTime)}`
                      : GROUP_STATE[state]}
              </p>
            </div>
            <div className="mt-5 flex flex-wrap items-center gap-2">
              <a href={addressUrl(group)} target="_blank" rel="noopener noreferrer" className="mono inline-flex min-h-9 items-center gap-1 text-xs hover:underline">
                {short(group)} <ExternalLink className="size-3" aria-hidden />
              </a>
              <Button variant="ghost" small disabled={!shareUrl} onClick={() => void copyLink()}>
                <Copy className="size-3.5" aria-hidden /> Copy circle link
              </Button>
            </div>
          </div>
          <CircleViz nodes={nodes} size={230}>
            <div>
              <div className="label-caps">{isActive ? 'Now' : 'Circle'}</div>
              <div className="display text-3xl font-bold tabular-nums">{isActive ? round : terms.n}</div>
              <div className="text-[11px]" style={{ color: 'var(--muted)' }}>
                {isActive ? `of ${terms.n} rounds` : 'members'}
              </div>
            </div>
          </CircleViz>
        </div>
      </Card>

      <Card>
        <SectionTitle
          icon={<UserRound className="size-4" aria-hidden />}
          title="Your position"
          action={mySlot > 0 && address ? <Avatar address={address} size={30} /> : undefined}
        />
        {!address ? (
          <p className="text-sm" style={{ color: 'var(--muted)' }}>
            Connect your wallet to see your status and take action.
          </p>
        ) : mySlot === 0 ? (
          <Callout>This wallet is not on the member list for this circle, so you can view it but not take part.</Callout>
        ) : (
          <>
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <Stat label="Position" value={`#${mySlot}`} sub={joined ? 'Joined' : 'Not joined yet'} />
              <Stat label="Deposit" value={`${fmt(me?.deposit)} USDC`} />
              <Stat label="Holdback" value={`${fmt(me?.holdback)} USDC`} sub="Withheld from your pot" />
              <Stat label="Claimable" value={`${fmt(myClaimable)} USDC`} />
            </div>
            {me && me.status === STATUS.Active && me.deposit < terms.d ? (
              <div className="mt-4">
                <Callout tone="warn" icon={<AlertTriangle className="size-4" aria-hidden />}>
                  Your deposit is short by {fmt(terms.d - me.deposit)} USDC. Until you top it up, your holdback is not released round by round.
                  <div className="mt-2">
                    <Button variant="ghost" small disabled={tx.busy} onClick={() => void topUp()}>
                      Top up deposit
                    </Button>
                  </div>
                </Callout>
              </div>
            ) : null}
          </>
        )}

        {primary.label ? (
          <div className="mt-5">
            <Button full disabled={!primary.run} loading={tx.busy} onClick={primary.run}>
              {tx.phase === 'wallet' ? 'Confirm in your wallet...' : tx.phase === 'confirming' ? 'Confirming onchain...' : primary.label}
            </Button>
          </div>
        ) : null}

        <div className="mt-3 flex flex-wrap gap-2">
          {needsSync ? (
            <Button variant="ghost" small disabled={tx.busy || !address} onClick={() => void write('sync', [], 'Circle status updated')}>
              Update circle status
            </Button>
          ) : null}
          {canWithdraw ? (
            <Button variant="danger" small disabled={tx.busy} onClick={() => void write('withdraw', [], state === STATE.Locked ? 'Circle cancelled, deposits refunded' : 'You left the circle')}>
              {state === STATE.Locked ? 'Leave (cancels the circle)' : 'Leave and reclaim deposit'}
            </Button>
          ) : null}
          {canCancel ? (
            <Button variant="danger" small disabled={tx.busy || !address} onClick={() => void write('cancel', [], 'Circle cancelled')}>
              Cancel circle (timed out)
            </Button>
          ) : null}
        </div>
        {tx.hash ? (
          <a href={txUrl(tx.hash)} target="_blank" rel="noopener noreferrer" className="mt-3 inline-flex items-center gap-1 text-xs hover:underline" style={{ color: 'var(--accent-hover)' }}>
            Latest transaction on the explorer <ExternalLink className="size-3" aria-hidden />
          </a>
        ) : null}
      </Card>

      {late.length > 0 ? (
        <Card>
          <SectionTitle
            icon={<AlertTriangle className="size-4" aria-hidden />}
            title="Overdue past the cure window"
            hint="Anyone can act. If the member's deposit is enough it pays the installment; if not, they default and are added to the default registry. Whoever triggers a default earns a small fixed fee from the defaulter's collateral."
          />
          <ul className="space-y-2">
            {late.slice(0, 8).map((l) => (
              <li key={`${l.t}-${l.member.slot}`} className="flex flex-wrap items-center gap-3 rounded-2xl p-3" style={{ background: 'var(--surface-strong)', border: '1px solid var(--border)' }}>
                <Avatar address={l.member.wallet} size={28} />
                <span className="min-w-0 flex-1 text-sm">
                  Round {l.t} · position {l.member.slot} <span className="mono text-xs">{short(l.member.wallet)}</span> owes {fmt(l.missing)} USDC
                </span>
                <Button variant="ghost" small disabled={tx.busy || !address} onClick={() => void write('resolveLate', [l.t, l.member.wallet], 'Resolved')}>
                  Use deposit or declare default
                </Button>
              </li>
            ))}
          </ul>
        </Card>
      ) : null}

      <RoundsList rounds={rounds} members={members} inst={inst} nowSec={nowSec} mySlot={mySlot} active={isActive} busy={tx.busy} onPay={(t, r) => void payRound(t, r)} />
      <MembersTable members={members} me={address} />
      <RulesCard terms={terms} termsHash={data.termsHash} inst={inst} group={group} />
      <p className="px-1 pb-8 text-xs" style={{ color: 'var(--subtle)' }}>
        {IS_MAINNET ? 'Arc mainnet: real funds.' : 'Arc Testnet only, no real value.'} Nobody guarantees principal. First round starts {fmtDate(terms.startTime)}.
      </p>
    </div>
  )
}

function BackButton({ onBack }: { onBack: () => void }) {
  return (
    <button onClick={onBack} className="flex min-h-11 items-center gap-1.5 text-sm font-semibold" style={{ color: 'var(--accent-hover)' }}>
      <ArrowLeft className="size-4" aria-hidden /> Back
    </button>
  )
}
