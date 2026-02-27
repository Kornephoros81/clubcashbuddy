import { defineStore } from 'pinia'
import { supabase } from '@/supabase'

export const useSession = defineStore('session', {
  state: () => ({ user: null as any }),
  actions: {
    async fetchUser() {
      const { data: { user } } = await supabase.auth.getUser()
      this.user = user
    },
    async signIn(email: string, password: string) {
      const { data, error } = await supabase.auth.signInWithPassword({ email, password })
      if (error) throw error
      this.user = data.user
    },
    async signOut() {
      await supabase.auth.signOut()
      this.user = null
    }
  }
})
