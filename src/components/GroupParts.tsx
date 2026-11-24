import type { ReactNode } from 'react'
import { Check, ExternalLink, Gavel, ListOrdered, Users } from 'lucide-react'
import type { Address } from 'viem'
import type { MemberRow, RoundRow } from '@/hooks/useGroupData'
import { MEMBER_STATUS, addressUrl, fmt, fmtDate, fmtDuration, short } from '@/lib/rosca'
import { Avatar, Badge, Button, Card, SectionTitle, Stat } from '@/components/ui'

type Terms = {
  n: number
  c: bigint
  phiBps: number
  d: bigint
  rho: bigint
  startTime: bigint
  period: bigint
  grace: bigint
  cure: bigint
  acceptDeadline: bigint
}

export function MembersTable({ members, me }: { members: MemberRow[]; me?: Address }) {
  return (
    <Card>
      <SectionTitle icon={<Users className="size-4" aria-hidden />} title="Members and collateral" hint="In payout order. Amounts are in USDC." />
      <div className="overflow-x-auto">
        <table className="w-full min-w-[560px] text-left text-sm">
          <thead>
            <tr className="label-caps">
              <th className="pb-2 pr-3 font-semibold">#</th>
              <th className="pb-2 pr-3 font-semibold">Member</th>
              <th className="pb-2 pr-3 font-semibold">Status</th>
              <th className="pb-2 pr-3 text-right font-semibold">Deposit</th>
              <th className="pb-2 pr-3 text-right font-semibold">Holdback</th>
              <th className="pb-2 text-right font-semibold">Claimable</th>
            </tr>
          </thead>
          <tbody className="tabular-nums">
            {members.map((m) => {
              const mine = me && m.wallet.toLowerCase() === me.toLowerCase()
              return (
                <tr key={m.slot} className="border-t" style={{ borderColor: 'var(--border)', background: mine ? 'rgba(133,177,237,0.12)' : undefined }}>
                  <td className="py-2.5 pr-3 font-semibold">{m.slot}</td>
                  <td className="py-2.5 pr-3">
                    <a href={addressUrl(m.wallet)} target="_blank" rel="noopener noreferrer" className="mono inline-flex items-center gap-2 text-xs hover:underline">
                      <Avatar address={m.wallet} size={26} />
                      {short(m.wallet)} <ExternalLink className="size-3" aria-hidden />
                    </a>
                    {mine ? <span className="ml-1.5 text-xs font-semibold">You</span> : null}
                  </td>
                  <td className="py-2.5 pr-3">
                    <Badge tone={m.status === 3 ? 'danger' : m.status === 2 ? 'success' : 'neutral'}>{MEMBER_STATUS[m.status] ?? '-'}</Badge>
                    {m.depositUses > 0 ? (
                      <span className="ml-1.5 text-xs" style={{ color: 'var(--warn)' }}>
                        deposit used {m.depositUses}x
                      </span>
                    ) : null}
                  </td>
                  <td className="py-2.5 pr-3 text-right">{fmt(m.deposit)}</td>
                  <td className="py-2.5 pr-3 text-right">{fmt(m.holdback)}</td>
                  <td className="py-2.5 text-right">{fmt(m.claimable)}</td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    </Card>
  )
}

function roundLabel(r: RoundRow, nowSec: number): { text: string; tone: 'neutral' | 'success' | 'danger' | 'warn' } {
  if (r.skipped) return { text: 'Skipped', tone: 'warn' }
  if (r.settled) return { text: 'Pot paid out', tone: 'success' }
  if (r.ready) return { text: 'Ready to pay out', tone: 'warn' }
  if (nowSec < Number(r.due)) return { text: 'Not due yet', tone: 'neutral' }
  return { text: 'Collecting', tone: 'neutral' }
}

export function RoundsList({
  rounds,
  members,
  inst,
  nowSec,
  mySlot,
  active,
  busy,
  onPay,
}: {
  rounds: RoundRow[]
  members: MemberRow[]
  inst: bigint
  nowSec: number
  mySlot: number
  active: boolean
  busy: boolean
  onPay: (t: number, remaining: bigint) => void
}): ReactNode {
  return (
    <Card>
      <SectionTitle icon={<ListOrdered className="size-4" aria-hidden />} title="Rounds" hint="One member takes the pot each round." />
      <ol className="relative space-y-3">
        {rounds.map((r, idx) => {
          const label = roundLabel(r, nowSec)
          const payers = members.filter((m) => m.slot !== r.t)
          const complete = payers.filter((m) => (r.principalPaid[m.slot - 1] ?? 0n) + (r.reservePaid[m.slot - 1] ?? 0n) >= inst).length
          const mineIdx = mySlot - 1
          const myPaid = mySlot > 0 ? (r.principalPaid[mineIdx] ?? 0n) + (r.reservePaid[mineIdx] ?? 0n) : 0n
          const canPay = active && mySlot > 0 && mySlot !== r.t && nowSec >= Number(r.due) && myPaid < inst && !r.skipped
          return (
            <li key={r.t} className="relative flex gap-3">
              {idx < rounds.length - 1 ? <span className="absolute left-4 top-9 -bottom-3 w-px" style={{ background: 'var(--border)' }} aria-hidden /> : null}
              <span
                className="display z-10 flex size-8 shrink-0 items-center justify-center rounded-full text-sm font-bold"
                style={{ background: r.settled ? 'var(--accent)' : 'var(--surface-strong)', color: r.settled ? '#fff' : 'var(--ink)', border: '1px solid var(--border)' }}
              >
                {r.settled ? <Check className="size-4" aria-hidden /> : r.t}
              </span>
              <div className="min-w-0 flex-1 rounded-2xl p-3.5" style={{ background: 'var(--surface-strong)', border: '1px solid var(--border)' }}>
                <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
                  <div className="flex min-w-0 flex-1 items-center gap-2.5">
                    <Avatar address={r.recipient} size={28} />
                    <div className="min-w-0">
                      <div className="truncate text-sm font-semibold">
                        <span className="mono text-xs">{short(r.recipient)}</span>
                        {mySlot === r.t ? <span className="ml-1.5 text-xs">You</span> : null}
                      </div>
                      <div className="text-xs tabular-nums" style={{ color: 'var(--muted)' }}>
                        Due {fmtDate(r.due)} · {complete}/{payers.length} paid in full
                      </div>
                    </div>
                  </div>
                  <Badge tone={label.tone}>{label.text}</Badge>
                </div>
                {canPay ? (
                  <Button variant="ghost" small className="mt-3" disabled={busy} onClick={() => onPay(r.t, inst - myPaid)}>
                    Pay {fmt(inst - myPaid)} USDC
                  </Button>
                ) : mySlot > 0 && mySlot !== r.t && myPaid >= inst ? (
                  <span className="mt-2 inline-flex items-center gap-1 text-xs font-semibold" style={{ color: 'var(--success)' }}>
                    <Check className="size-4" aria-hidden /> You have paid this round
                  </span>
                ) : null}
              </div>
            </li>
          )
        })}
      </ol>
    </Card>
  )
}

export function RulesCard({ terms, termsHash, inst, group }: { terms: Terms; termsHash?: string; inst: bigint; group: Address }) {
  return (
    <Card>
      <SectionTitle icon={<Gavel className="size-4" aria-hidden />} title="Rules locked in the contract" hint="These cannot be changed by anyone after creation." />
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Stat label="Installment" value={`${fmt(terms.c)} USDC`} sub={terms.rho > 0n ? `+ ${fmt(terms.rho)} reserve` : undefined} />
        <Stat label="Pot per round" value={`${fmt(terms.c * BigInt(terms.n))} USDC`} />
        <Stat label="Deposit" value={`${fmt(terms.d)} USDC`} sub="Per member" />
        <Stat label="Holdback" value={`${terms.phiBps / 100}%`} sub="Released as you keep paying" />
        <Stat label="Round interval" value={fmtDuration(Number(terms.period))} />
        <Stat label="Grace / cure" value={`${fmtDuration(Number(terms.grace))} / ${fmtDuration(Number(terms.cure))}`} />
        <Stat label="Join deadline" value={fmtDate(terms.acceptDeadline)} />
        <Stat label="First round" value={fmtDate(terms.startTime)} />
        <Stat label="Full installment" value={`${fmt(inst)} USDC`} />
      </div>
      <div className="mt-4 space-y-1 text-xs" style={{ color: 'var(--muted)' }}>
        <div>
          Contract:{' '}
          <a href={addressUrl(group)} target="_blank" rel="noopener noreferrer" className="mono break-all hover:underline">
            {group}
          </a>
        </div>
        {termsHash ? <div className="mono break-all">Terms hash: {termsHash}</div> : null}
      </div>
    </Card>
  )
}
