import { useCallback, useState } from 'react'
import { useAccount } from 'wagmi'
import { useQueryClient } from '@tanstack/react-query'
import { switchChain, waitForTransactionReceipt, writeContract } from 'wagmi/actions'
import type { Abi, Address, Hash, TransactionReceipt } from 'viem'
import { toast } from 'sonner'
import { config } from '@/config'
import { CHAIN_ID, parseError } from '@/lib/rosca'

export interface WriteRequest {
  address: Address
  abi: Abi
  functionName: string
  args?: readonly unknown[]
}

export type TxPhase = 'idle' | 'wallet' | 'confirming'

/** Runs one contract write against Arc Testnet and reports real wallet and receipt phases. */
export function useTx() {
  const { chainId, isConnected } = useAccount()
  const queryClient = useQueryClient()
  const [phase, setPhase] = useState<TxPhase>('idle')
  const [hash, setHash] = useState<Hash | undefined>()

  const run = useCallback(
    async (request: WriteRequest, successMessage: string): Promise<TransactionReceipt | undefined> => {
      if (!isConnected) return undefined
      try {
        setPhase('wallet')
        if (chainId !== CHAIN_ID) await switchChain(config, { chainId: CHAIN_ID })
        const txHash = await writeContract(config, { ...request, chainId: CHAIN_ID })
        setHash(txHash)
        setPhase('confirming')
        const receipt = await waitForTransactionReceipt(config, { hash: txHash, chainId: CHAIN_ID })
        if (receipt.status !== 'success') {
          toast.error('The transaction failed onchain.')
          return undefined
        }
        toast.success(successMessage)
        await queryClient.invalidateQueries()
        return receipt
      } catch (error) {
        const message = parseError(error)
        if (message) toast.error(message)
        return undefined
      } finally {
        setPhase('idle')
      }
    },
    [chainId, isConnected, queryClient],
  )

  return { run, phase, hash, busy: phase !== 'idle' }
}
