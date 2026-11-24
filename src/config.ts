/**
 * wagmi configuration
 * Built with Arc Studio — https://studio.arc.io
 */

import { http, createConfig } from 'wagmi'
import { mainnet } from 'wagmi/chains'
import { arc, arcTestnet } from 'viem/chains'
import { requireChain } from './onchain-facts'
import { injected } from 'wagmi/connectors'
import { registerChain } from './tracing'

// Pre-register chain RPC URLs so trace events show correct chain names immediately
const rpcFor = (id: number) => requireChain(id).rpcUrls[0]
registerChain(arcTestnet.id, rpcFor(arcTestnet.id))
registerChain(arc.id, rpcFor(arc.id))

export const config = createConfig({
  chains: [arcTestnet, arc, mainnet], // mainnet needed for ENS resolution
  connectors: [injected()],
  transports: {
    [arcTestnet.id]: http(rpcFor(arcTestnet.id)),
    [arc.id]: http(rpcFor(arc.id)),
    [mainnet.id]: http(), // ENS resolution uses mainnet
  },
})
