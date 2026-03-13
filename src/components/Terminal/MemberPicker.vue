<!-- src/components/MemberList.vue -->
<script setup lang="ts">
import { ref, computed, inject } from "vue";
import { useCatalog } from "@/stores/useCatalog";
import { useTerminalLogic } from "@/composables/useTerminalLogic";

const emit = defineEmits<{ (e: "select", id: string): void }>();

const store = useCatalog();
const terminalLogic = inject("terminalLogic") as ReturnType<
  typeof useTerminalLogic
>;
const bookedTodayIds = terminalLogic.bookedTodayIds;

const selectedLetter = ref<string>("");
const selected = ref<string | null>(null);
const alphabet = Array.from("ABCDEFGHIJKLMNOPQRSTUVWXYZ");

// Nachname Initial
function getLastNameInitial(name: string): string {
  if (!name) return "";
  const [last] = String(name).split(",");
  const lastName = (last ?? name).trim();
  return lastName.charAt(0)?.toUpperCase() || "";
}

const availableLetters = computed(() => {
  const letters: string[] = [];
  for (const m of store.members) {
    const letter = getLastNameInitial(m.name);
    if (letter && !letters.includes(letter)) letters.push(letter);
  }
  return letters.sort();
});

function isInactive(m: any) {
  const THIRTY = 1000 * 60 * 60 * 24 * 30;
  if (!m.last_booking_at) return true;
  return Date.now() - new Date(m.last_booking_at).getTime() > THIRTY;
}

const filteredMembers = computed(() => {
  const now = Date.now();
  const THIRTY = 1000 * 60 * 60 * 24 * 30;

  const sorted = [...store.members].sort((a, b) => {
    const aLast = a.last_booking_at ? new Date(a.last_booking_at).getTime() : 0;
    const bLast = b.last_booking_at ? new Date(b.last_booking_at).getTime() : 0;
    const aInactive = now - aLast > THIRTY;
    const bInactive = now - bLast > THIRTY;

    if (aInactive !== bInactive) return aInactive ? 1 : -1;
    return a.name.localeCompare(b.name, "de");
  });

  if (!selectedLetter.value) return sorted;
  return sorted.filter(
    (m) => getLastNameInitial(m.name) === selectedLetter.value
  );
});

function toggleLetter(ch: string) {
  selectedLetter.value = selectedLetter.value === ch ? "" : ch;
}

function selectMember(id: string) {
  selected.value = id;
  emit("select", id);
}

function splitMemberName(name: string) {
  if (!name) return { lastName: "", firstName: "" };
  const [last, ...rest] = String(name).split(",");
  return {
    lastName: (last ?? "").trim(),
    firstName: rest.join(",").trim(),
  };
}
</script>

<template>
  <div class="flex flex-col h-full w-full bg-gray-50 overflow-hidden">
    <!-- Buchstaben -->
    <div class="bg-gray-50 border-b border-gray-200 px-2 py-2">
      <div class="flex overflow-x-auto justify-center gap-1.5">
        <button
          v-for="ch in alphabet"
          :key="ch"
          @click="availableLetters.includes(ch) && toggleLetter(ch)"
          :disabled="!availableLetters.includes(ch)"
          class="rounded-lg min-w-[2rem] h-9 flex items-center justify-center font-semibold border text-base transition px-2"
          :class="[
            selectedLetter === ch
              ? 'bg-blue-600 text-white border-blue-600'
              : availableLetters.includes(ch)
              ? 'bg-white text-gray-700 border-gray-300 hover:bg-blue-50 hover:text-blue-700'
              : 'bg-gray-100 text-gray-400 border-gray-200 cursor-not-allowed',
          ]"
        >
          {{ ch }}
        </button>
      </div>
    </div>

    <!-- Mitglieder -->
    <div
      class="flex-1 min-h-0 overflow-y-auto grid grid-cols-3 sm:grid-cols-4 md:grid-cols-5 lg:grid-cols-6 gap-2 p-2 content-start"
    >
      <template v-for="(m, i) in filteredMembers" :key="m.id">
        <div
          v-if="i > 0 && isInactive(m) && !isInactive(filteredMembers[i - 1])"
          class="col-span-full text-center my-2 border-t-2 border-dashed border-gray-400 text-gray-500 text-sm py-1"
        >
          Länger als 30 Tage nicht gebucht ↓
        </div>

        <button
          @click="selectMember(m.id)"
          class="base-tile h-20 rounded-xl border-[1.5px] shadow-sm transition flex flex-col items-center justify-center text-center px-3 py-3"
          :class="[
            m.is_guest
              ? 'bg-amber-100 text-gray-800 border-amber-300 hover:bg-amber-200'
              : m.id === selected
              ? 'bg-primary text-white border-primary scale-[1.04]'
              : bookedTodayIds.has(m.id)
              ? 'bg-emerald-100 text-gray-800 border-emerald-300 hover:bg-emerald-200'
              : 'bg-white text-gray-800 border-gray-300 hover:bg-gray-100',
          ]"
        >
          <span class="px-1 whitespace-normal break-words text-center">
            <span
              class="block text-[clamp(0.9rem,1vw+0.4rem,1.2rem)] font-semibold leading-tight"
            >
              {{ splitMemberName(m.name).lastName }}
            </span>
            <span
              v-if="splitMemberName(m.name).firstName"
              class="block text-[clamp(0.7rem,1vw+0.2rem,1rem)] text-gray-500 leading-tight"
            >
              {{ splitMemberName(m.name).firstName }}
            </span>
          </span>
        </button>
      </template>

      <p
        v-if="!filteredMembers.length"
        class="col-span-full text-center text-gray-500 py-3"
      >
        Kein Mitglied gefunden
      </p>
    </div>
  </div>
</template>

<style scoped>
::-webkit-scrollbar {
  height: 4px;
  width: 6px;
}
::-webkit-scrollbar-thumb {
  background-color: rgba(0, 0, 0, 0.25);
  border-radius: 3px;
}
</style>
