import { ConnectKitButton } from 'connectkit'
import { useAccount, useReadContract } from 'wagmi'
import { erc20Abi } from 'viem'
import { TokenUSDC } from '@web3icons/react'
import { CHAIN_ID, IS_MAINNET, NETWORK_NAME, USDC, fmt } from '@/lib/rosca'

function Mark() {
  return (
    <svg viewBox="0 0 40 40" className="size-10" aria-hidden>
      <rect width="40" height="40" rx="12" fill="#122d45" />
      <circle cx="20" cy="20" r="9.5" fill="none" stroke="#85b1ed" strokeWidth="1.4" strokeDasharray="1.6 3" />
      {[0, 1, 2, 3, 4, 5].map((i) => {
        const a = (-90 + i * 60) * (Math.PI / 180)
        return <circle key={i} cx={20 + 9.5 * Math.cos(a)} cy={20 + 9.5 * Math.sin(a)} r={i === 1 ? 2.6 : 1.9} fill={i === 1 ? '#f7d9a8' : '#ffffff'} />
      })}
    </svg>
  )
}

export function Header({ onHome }: { onHome: () => void }) {
  const { address } = useAccount()
  const { data: balance } = useReadContract({
    address: USDC,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    chainId: CHAIN_ID,
    query: { enabled: Boolean(address), refetchInterval: 15_000 },
  })

  return (
    <header className="flex items-center justify-between gap-3 py-5">
      <button onClick={onHome} className="flex min-h-11 items-center gap-3 text-left" aria-label="Back to home">
        <Mark />
        <span>
          <span className="display block text-xl font-bold leading-none">Rosca Circle</span>
          <span className="mt-1 flex items-center gap-1.5 text-[11px] font-medium" style={{ color: 'var(--muted)' }}>
            <span className="size-1.5 rounded-full" style={{ background: IS_MAINNET ? 'var(--warn)' : 'var(--success)' }} aria-hidden />
            {NETWORK_NAME}{IS_MAINNET ? ' mainnet' : ''}
          </span>
        </span>
      </button>
      <div className="flex items-center gap-2">
        {address && balance !== undefined ? (
          <span
            className="hidden items-center gap-1.5 rounded-full px-3 py-2 text-xs font-semibold tabular-nums sm:flex"
            style={{ background: 'var(--surface-strong)', border: '1px solid var(--border)' }}
          >
            <TokenUSDC variant="branded" size={16} />
            {fmt(balance)} USDC
          </span>
        ) : null}
        <ConnectKitButton label="Connect wallet" />
      </div>
    </header>
  )
}
