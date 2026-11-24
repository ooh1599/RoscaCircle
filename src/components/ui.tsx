import type { ButtonHTMLAttributes, CSSProperties, InputHTMLAttributes, ReactNode } from 'react'
import { Loader2 } from 'lucide-react'
import { clsx } from 'clsx'

export const glass: Record<'card' | 'inner', CSSProperties> = {
  card: {
    background: 'var(--surface)',
    border: '1px solid var(--border)',
    backdropFilter: 'blur(24px) saturate(160%)',
    WebkitBackdropFilter: 'blur(24px) saturate(160%)',
    boxShadow: '0 10px 36px rgba(18,45,69,0.06), inset 0 1px 0 rgba(255,255,255,0.8)',
  },
  inner: {
    background: 'var(--surface-strong)',
    border: '1px solid var(--border)',
  },
}

export function Card({
  children,
  className,
  strong,
  spectral,
}: {
  children: ReactNode
  className?: string
  strong?: boolean
  spectral?: boolean
}) {
  return (
    <section className={clsx('rise-in relative overflow-hidden rounded-3xl p-5 sm:p-6', className)} style={strong ? glass.inner : glass.card}>
      {spectral ? <div className="spectral absolute inset-x-0 top-0 h-1" aria-hidden /> : null}
      {children}
    </section>
  )
}

export function Inner({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div className={clsx('rounded-2xl p-4', className)} style={{ background: 'var(--surface-muted)' }}>
      {children}
    </div>
  )
}

export function SectionTitle({ icon, title, hint, action }: { icon?: ReactNode; title: string; hint?: string; action?: ReactNode }) {
  return (
    <div className="mb-4 flex items-start justify-between gap-3">
      <div className="flex min-w-0 items-start gap-2.5">
        {icon ? (
          <span className="mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-xl" style={{ background: 'var(--surface-muted)', color: 'var(--accent-hover)' }}>
            {icon}
          </span>
        ) : null}
        <div className="min-w-0">
          <h2 className="display text-lg font-semibold leading-tight">{title}</h2>
          {hint ? (
            <p className="mt-0.5 text-pretty text-xs" style={{ color: 'var(--muted)' }}>
              {hint}
            </p>
          ) : null}
        </div>
      </div>
      {action}
    </div>
  )
}

export function Stat({ label, value, sub, mono }: { label: string; value: ReactNode; sub?: ReactNode; mono?: boolean }) {
  return (
    <div className="min-w-0 rounded-2xl p-3" style={{ background: 'var(--surface-muted)' }}>
      <div className="label-caps">{label}</div>
      <div className={clsx('mt-1 truncate text-base font-semibold tabular-nums', mono && 'mono text-sm')} style={{ color: 'var(--ink)' }}>
        {value}
      </div>
      {sub ? (
        <div className="mt-0.5 text-pretty text-xs" style={{ color: 'var(--muted)' }}>
          {sub}
        </div>
      ) : null}
    </div>
  )
}

type Tone = 'neutral' | 'success' | 'danger' | 'warn'
const toneColor: Record<Tone, string> = {
  neutral: 'var(--ink-2)',
  success: 'var(--success)',
  danger: 'var(--danger)',
  warn: 'var(--warn)',
}
const toneDot: Record<Tone, string> = {
  neutral: '#9aa7b8',
  success: 'var(--success)',
  danger: 'var(--danger)',
  warn: '#d9a21b',
}

export function Badge({ children, tone = 'neutral' }: { children: ReactNode; tone?: Tone }) {
  return (
    <span
      className="inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2.5 py-1 text-xs font-semibold"
      style={{ color: toneColor[tone], background: 'var(--surface-strong)', border: '1px solid var(--border)' }}
    >
      <span className="size-1.5 rounded-full" style={{ background: toneDot[tone] }} aria-hidden />
      {children}
    </span>
  )
}

export function Callout({ icon, tone = 'neutral', children }: { icon?: ReactNode; tone?: Tone; children: ReactNode }) {
  return (
    <div className="flex gap-2.5 rounded-2xl p-3.5 text-xs" style={{ background: 'var(--surface-muted)', color: tone === 'neutral' ? 'var(--ink-2)' : toneColor[tone] }}>
      {icon ? <span className="mt-0.5 shrink-0">{icon}</span> : null}
      <div className="text-pretty leading-relaxed">{children}</div>
    </div>
  )
}

export function ProgressBar({ value, max, label }: { value: number; max: number; label?: string }) {
  const pct = max > 0 ? Math.min(100, Math.max(0, (value / max) * 100)) : 0
  return (
    <div role="progressbar" aria-valuemin={0} aria-valuemax={max} aria-valuenow={value} aria-label={label} className="h-2 w-full overflow-hidden rounded-full" style={{ background: 'var(--surface-muted)' }}>
      <div className="h-full rounded-full transition-[width] duration-700" style={{ width: `${pct}%`, background: 'var(--accent)' }} />
    </div>
  )
}

/** Deterministic pastel avatar from a wallet address. */
export function Avatar({ address, size = 32 }: { address: string; size?: number }) {
  const seed = parseInt(address.slice(2, 8), 16) || 0
  const hue = seed % 360
  return (
    <span
      className="inline-flex shrink-0 items-center justify-center rounded-full text-[10px] font-bold"
      style={{
        width: size,
        height: size,
        color: 'var(--ink)',
        background: `linear-gradient(135deg, hsl(${hue} 78% 84%), hsl(${(hue + 48) % 360} 72% 74%))`,
        border: '1px solid rgba(255,255,255,0.8)',
      }}
      aria-hidden
    >
      {address.slice(2, 4).toUpperCase()}
    </span>
  )
}

export function Skeleton({ className }: { className?: string }) {
  return <div className={clsx('skeleton', className)} aria-hidden />
}

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'primary' | 'ghost' | 'danger'
  loading?: boolean
  full?: boolean
  small?: boolean
}

export function Button({ variant = 'primary', loading, full, small, className, children, disabled, ...rest }: ButtonProps) {
  const style: CSSProperties =
    variant === 'primary'
      ? { background: 'var(--accent)', color: '#fff', boxShadow: '0 6px 18px rgba(18,45,69,0.22)' }
      : variant === 'danger'
        ? { background: 'transparent', color: 'var(--danger)', border: '1px solid var(--border)' }
        : { background: 'var(--surface-strong)', color: 'var(--ink)', border: '1px solid var(--border)' }
  return (
    <button
      {...rest}
      disabled={disabled || loading}
      className={clsx(
        'inline-flex items-center justify-center gap-2 rounded-2xl font-semibold transition-all',
        small ? 'min-h-9 px-3 py-1.5 text-xs' : 'min-h-12 px-5 py-3 text-sm',
        'hover:scale-[1.01] active:scale-[0.99] disabled:cursor-not-allowed disabled:opacity-40 disabled:hover:scale-100',
        full && 'w-full',
        className,
      )}
      style={style}
    >
      {loading ? <Loader2 className="size-4 animate-spin" aria-hidden /> : null}
      {children}
    </button>
  )
}

interface FieldProps extends InputHTMLAttributes<HTMLInputElement> {
  label: string
  hint?: string
  suffix?: string
  error?: string
}

export function Field({ label, hint, suffix, error, className, ...rest }: FieldProps) {
  return (
    <label className={clsx('block', className)}>
      <span className="label-caps">{label}</span>
      <div
        className="mt-1.5 flex items-center gap-2 rounded-2xl px-3.5 transition-shadow focus-within:shadow-[0_0_0_3px_rgba(133,177,237,0.35)]"
        style={{ background: 'var(--surface-strong)', border: `1px solid ${error ? 'var(--danger)' : 'var(--border)'}` }}
      >
        <input
          {...rest}
          className="min-h-11 w-full min-w-0 bg-transparent text-sm tabular-nums outline-none placeholder:text-slate-400"
          style={{ color: 'var(--ink)' }}
        />
        {suffix ? (
          <span className="shrink-0 text-xs font-medium" style={{ color: 'var(--subtle)' }}>
            {suffix}
          </span>
        ) : null}
      </div>
      {error ? (
        <span className="mt-1 block text-xs" style={{ color: 'var(--danger)' }}>
          {error}
        </span>
      ) : hint ? (
        <span className="mt-1 block text-pretty text-xs" style={{ color: 'var(--muted)' }}>
          {hint}
        </span>
      ) : null}
    </label>
  )
}
