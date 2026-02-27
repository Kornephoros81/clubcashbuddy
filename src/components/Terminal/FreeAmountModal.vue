<script setup lang="ts">
import { ref } from "vue";
import BaseModal from "@/components/BaseModal.vue";

const props = defineProps<{
  show: boolean;
}>();

const emit = defineEmits<{
  (e: "close"): void;
  (e: "confirm", amount: number, note: string, transactionType: "sale_free_amount" | "cash_withdrawal"): void;
}>();

const amount = ref("");
const note = ref("");
const transactionType = ref<"sale_free_amount" | "cash_withdrawal">("sale_free_amount");
const error = ref<string | null>(null);

function handleConfirm() {
  const raw = amount.value.trim().replace(",", ".");
  const validPattern = /^(?:\d+|\d+\.\d{1,2})$/;

  if (!validPattern.test(raw)) {
    error.value = "Bitte eine gültige positive Zahl eingeben";
    return;
  }

  const euro = parseFloat(raw);
  if (isNaN(euro) || euro <= 0) {
    error.value = "Bitte eine gültige positive Zahl eingeben";
    return;
  }

  emit("confirm", euro, note.value, transactionType.value);
  amount.value = "";
  note.value = "";
  transactionType.value = "sale_free_amount";
  error.value = null;
}
</script>

<template>
  <BaseModal
    :show="show"
    title="💶 Freien Betrag buchen"
    confirm-label="Buchen"
    cancel-label="Abbrechen"
    @close="emit('close')"
    @confirm="handleConfirm"
  >
    <div class="space-y-4">
      <div>
        <label class="block text-sm text-gray-600 font-medium">Art</label>
        <select
          v-model="transactionType"
          class="w-full p-2 rounded-md border border-gray-300 focus:ring-2 focus:ring-primary"
        >
          <option value="sale_free_amount">Freier Verkauf (umsatzrelevant)</option>
          <option value="cash_withdrawal">Bar-Entnahme (kein Umsatz)</option>
        </select>
      </div>

      <!-- Betrag -->
      <div>
        <label class="block text-sm text-gray-600 font-medium">Betrag (€)</label>
        <input
          v-model="amount"
          type="text"
          inputmode="decimal"
          placeholder="z. B. 3,50"
          class="w-full p-2 rounded-md border focus:ring-2 focus:ring-primary transition"
          :class="error ? 'border-red-500 bg-red-50' : 'border-gray-300'"
          @input="error = null"
        />
      </div>

      <!-- Notiz -->
      <div>
        <label class="block text-sm text-gray-600 font-medium"
          >Notiz (optional)</label
        >
        <input
          v-model="note"
          type="text"
          placeholder="z. B. „Brötchen“"
          class="w-full p-2 rounded-md border border-gray-300 focus:ring-2 focus:ring-primary"
        />
      </div>

      <p v-if="error" class="text-red-600 text-sm mt-1 font-medium">
        ⚠️ {{ error }}
      </p>
    </div>
  </BaseModal>
</template>
