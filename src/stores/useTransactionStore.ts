// src/stores/useTransactionStore.ts
import { defineStore } from "pinia"

export interface Transaction {
  id: string
  member_id: string
  product_id: string | null
  amount: number
  note?: string | null
  synced?: boolean
  cancel_tx_id?: string | null
}

export const useTransactionStore = defineStore("transactions", {
  state: () => ({
    items: [] as Transaction[],
  }),

  getters: {
    total: (state) => state.items.reduce((sum, t) => sum + t.amount, 0),
  },

  actions: {
    /** Fügt eine neue Buchung hinzu oder entfernt eine stornierte */
    add(tx: Transaction) {
      if (tx.cancel_tx_id) {
        const idx = this.items.findIndex((t) => t.id === tx.cancel_tx_id)
        if (idx !== -1) {
          this.items.splice(idx, 1)
          console.log("[TransactionStore] removed cancelled tx:", tx.cancel_tx_id)
        }
        return
      }
      this.items.push(tx)
    },

    /** Löscht eine Buchung manuell */
    remove(id: string) {
      const idx = this.items.findIndex((t) => t.id === id)
      if (idx !== -1) this.items.splice(idx, 1)
    },

    /** Wird beim Offline-Sync aufgerufen */
    handleSyncResult(result: any) {
      if (result.cancelled) {
        this.remove(result.cancelled)
      } else if (result.success && result.data) {
        this.add(result.data)
      }
    },

    clear() {
      this.items = []
    },
  },
})
