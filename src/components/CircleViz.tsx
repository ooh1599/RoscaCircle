import type { ReactNode } from 'react'

export type NodeTone = 'done' | 'current' | 'upcoming' | 'bad' | 'skipped'

export interface CircleNode {
  label: string
  tone: NodeTone
}

const fill: Record<NodeTone, { bg: string; fg: string; stroke: string }> = {
  done: { bg: '#122d45', fg: '#ffffff', stroke: '#122d45' },
  current: { bg: '#1061a6', fg: '#ffffff', stroke: '#1061a6' },
  upcoming: { bg: '#ffffff', fg: '#122d45', stroke: 'rgba(18,45,69,0.22)' },
  bad: { bg: '#ba2b4c', fg: '#ffffff', stroke: '#ba2b4c' },
  skipped: { bg: '#f3e6c4', fg: '#7a5810', stroke: '#d9a21b' },
}

/** A ring of members in payout order. Each node shows its position; the centre holds a short summary. */
export function CircleViz({ nodes, size = 260, children, decorative }: { nodes: CircleNode[]; size?: number; children?: ReactNode; decorative?: boolean }) {
  const n = Math.max(nodes.length, 1)
  const radius = 38
  return (
    <div className="relative mx-auto" style={{ width: size, height: size }} aria-hidden={decorative} role={decorative ? undefined : 'img'} aria-label={decorative ? undefined : 'Members in payout order'}>
      <svg viewBox="0 0 100 100" className="absolute inset-0 size-full">
        <defs>
          <linearGradient id="ring-grad" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0%" stopColor="#85b1ed" />
            <stop offset="35%" stopColor="#b9a7f0" />
            <stop offset="65%" stopColor="#f2b8c6" />
            <stop offset="100%" stopColor="#a8e0c0" />
          </linearGradient>
        </defs>
        <circle cx="50" cy="50" r={radius} fill="none" stroke="rgba(18,45,69,0.08)" strokeWidth="7" />
        <circle cx="50" cy="50" r={radius} fill="none" stroke="url(#ring-grad)" strokeWidth="0.8" strokeDasharray="1.2 2.4" opacity="0.9" />
        {nodes.map((node, i) => {
          const angle = (-90 + (360 / n) * i) * (Math.PI / 180)
          const x = 50 + radius * Math.cos(angle)
          const y = 50 + radius * Math.sin(angle)
          const c = fill[node.tone]
          return (
            <g key={i}>
              {node.tone === 'current' ? <circle className="ring-pulse" cx={x} cy={y} r="7" fill="none" stroke="#1061a6" strokeWidth="1" /> : null}
              <circle cx={x} cy={y} r="7.2" fill={c.bg} stroke={c.stroke} strokeWidth="1" />
              <text x={x} y={y + 2.1} textAnchor="middle" fontSize="6" fontWeight="700" fill={c.fg} style={{ fontFamily: "'Space Grotesk', sans-serif" }}>
                {node.label}
              </text>
            </g>
          )
        })}
      </svg>
      <div className="absolute inset-0 flex items-center justify-center px-[26%] text-center">{children}</div>
    </div>
  )
}
