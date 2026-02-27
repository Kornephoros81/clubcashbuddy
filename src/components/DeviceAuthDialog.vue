<script setup lang="ts">
import { ref, watchEffect } from 'vue'
import { useDeviceAuthStore } from '@/stores/useDeviceAuthStore'

const authStore = useDeviceAuthStore()

const pairCode = ref('')
const errorMsg = ref('')
const loading = ref(false)

// Wenn Gerät schon authentifiziert → Dialog sofort schließen
watchEffect(() => {
  if (authStore.authenticated && !authStore.initializing) {
    errorMsg.value = ''
    pairCode.value = ''
  }
})

async function handleSubmit() {
  if (!pairCode.value.trim()) return

  errorMsg.value = ''
  loading.value = true
  try {
    await authStore.authenticateDevice(pairCode.value.trim())
    pairCode.value = ''
  } catch (err: any) {
    errorMsg.value = err?.message || 'Fehler bei der Geräte-Authentifizierung'
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <!-- Dialog nur anzeigen, wenn Gerät NICHT authentifiziert ist -->
  <div
    v-if="!authStore.authenticated && !authStore.initializing"
    class="fixed inset-0 flex items-center justify-center bg-gray-100 z-50"
  >
    <div class="bg-white p-6 rounded-2xl shadow-lg w-80 text-center">
      <h2 class="text-xl font-bold mb-4">Geräteaktivierung</h2>

      <input
        v-model="pairCode"
        type="text"
        inputmode="numeric"
        maxlength="6"
        placeholder="Pairing-Code eingeben"
        class="border p-2 w-full rounded mb-3 text-center focus:outline-none focus:ring-2 focus:ring-blue-400"
        @keyup.enter="handleSubmit"
        :disabled="loading"
      />

      <button
        @click="handleSubmit"
        :disabled="loading"
        class="w-full bg-blue-600 text-white py-2 rounded hover:bg-blue-700 transition disabled:opacity-60"
      >
        <span v-if="!loading">Koppeln</span>
        <span v-else>⏳ Wird überprüft...</span>
      </button>

      <p
        v-if="errorMsg"
        class="text-red-600 text-center mt-3 text-sm"
      >
        {{ errorMsg }}
      </p>
    </div>
  </div>
</template>
