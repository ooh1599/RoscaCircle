import { useCallback, useEffect, useState } from 'react'
import { isAddress, type Address } from 'viem'
import { Header } from '@/components/Header'
import { GroupList } from '@/components/GroupList'
import { CreateGroup } from '@/components/CreateGroup'
import { GroupView } from '@/components/GroupView'
import { Callout, Card } from '@/components/ui'
import { CONFIG_ERROR, IS_MAINNET } from '@/lib/rosca'
import { AlertTriangle } from 'lucide-react'

type View = { name: 'home' } | { name: 'create' } | { name: 'group'; address: Address }

const readView = (): View => {
  const g = new URLSearchParams(window.location.search).get('group')
  return g && isAddress(g) ? { name: 'group', address: g } : { name: 'home' }
}

export default function App() {
  const [view, setView] = useState<View>(readView)

  const go = useCallback((next: View) => {
    setView(next)
    const url = next.name === 'group' ? `/?group=${next.address}` : '/'
    window.history.pushState(null, '', url)
    window.scrollTo({ top: 0 })
  }, [])

  useEffect(() => {
    const onPop = () => setView(readView())
    window.addEventListener('popstate', onPop)
    return () => window.removeEventListener('popstate', onPop)
  }, [])

  const home = () => go({ name: 'home' })

  return (
    <div className="mx-auto min-h-dvh w-full max-w-3xl px-4 pb-24">
      <Header onHome={home} />
      {IS_MAINNET ? (
        <Callout tone="warn" icon={<AlertTriangle className="size-4" aria-hidden />}>
          Arc mainnet. Transactions use real USDC and cannot be undone. These contracts have not had an independent audit and nobody guarantees principal. Check the contract addresses before you approve or pay.
        </Callout>
      ) : null}
      {CONFIG_ERROR ? (
        <Card className="mt-4 p-6">
          <h1 className="display text-xl font-bold">Setup needed</h1>
          <p className="mt-2 text-sm" style={{ color: 'var(--muted)' }}>{CONFIG_ERROR}</p>
        </Card>
      ) : (
      <main>
        {view.name === 'home' ? <GroupList onOpen={(address) => go({ name: 'group', address })} onCreate={() => go({ name: 'create' })} /> : null}
        {view.name === 'create' ? <CreateGroup onBack={home} onCreated={(address) => go({ name: 'group', address })} /> : null}
        {view.name === 'group' ? <GroupView key={view.address} group={view.address} onBack={home} /> : null}
      </main>
      )}
    </div>
  )
}
