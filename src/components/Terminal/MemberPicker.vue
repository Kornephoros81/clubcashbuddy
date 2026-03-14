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
  <div class="glass-panel flex flex-col h-full w-full overflow-hidden rounded-[28px]">
    <!-- Buchstaben -->
    <div class="border-b border-slate-200/70 px-3 py-3">
      <div class="mb-2 flex items-center justify-between gap-3">
        <div class="section-chip">Mitglieder</div>
        <div class="text-xs font-medium text-slate-500">
          {{ filteredMembers.length }} sichtbar
        </div>
      </div>
      <div class="soft-scrollbar touch-scroll flex overflow-x-auto justify-center gap-1.5 pb-1">
        <button
          v-for="ch in alphabet"
          :key="ch"
          @click="availableLetters.includes(ch) && toggleLetter(ch)"
          :disabled="!availableLetters.includes(ch)"
          class="rounded-2xl min-w-[2.3rem] h-10 flex items-center justify-center font-semibold border text-[0.95rem] transition px-2 shadow-sm"
          :class="[
            selectedLetter === ch
              ? 'bg-slate-900 text-white border-slate-900 shadow-md'
              : availableLetters.includes(ch)
              ? 'bg-white/90 text-slate-700 border-slate-200 hover:bg-blue-50 hover:text-blue-700 hover:border-blue-200'
              : 'bg-slate-100 text-slate-300 border-slate-200 cursor-not-allowed',
          ]"
        >
          {{ ch }}
        </button>
      </div>
    </div>

    <!-- Mitglieder -->
    <div
      class="soft-scrollbar touch-scroll flex-1 min-h-0 overflow-y-auto grid grid-cols-3 sm:grid-cols-4 md:grid-cols-5 lg:grid-cols-6 gap-2.5 p-3 content-start"
    >
      <template v-for="(m, i) in filteredMembers" :key="m.id">
        <div
          v-if="i > 0 && isInactive(m) && !isInactive(filteredMembers[i - 1])"
          class="col-span-full text-center my-2 border-t border-dashed border-slate-300 text-slate-500 text-sm py-2"
        >
          Länger als 30 Tage nicht gebucht ↓
        </div>

        <button
          @click="selectMember(m.id)"
          class="group relative h-[5.4rem] rounded-[22px] border transition flex flex-col items-center justify-center text-center px-3 py-3 overflow-hidden"
          :class="[
            m.is_guest
              ? 'bg-gradient-to-br from-amber-50 to-orange-100 text-slate-800 border-amber-200 hover:border-amber-300 hover:shadow-md'
              : m.id === selected
              ? 'bg-gradient-to-br from-primary to-blue-700 text-white border-blue-800 scale-[1.02] shadow-lg'
              : bookedTodayIds.has(m.id)
              ? 'bg-gradient-to-br from-emerald-50 to-teal-100 text-slate-800 border-emerald-200 hover:border-emerald-300 hover:shadow-md'
              : 'bg-white/92 text-slate-800 border-slate-200 hover:border-blue-200 hover:bg-slate-50 hover:shadow-md',
          ]"
        >
          <span
            class="absolute inset-x-3 top-2 h-px opacity-70"
            :class="m.id === selected ? 'bg-white/40' : 'bg-slate-200'"
          ></span>
          <span class="px-1 whitespace-normal break-words text-center">
            <span
              class="block text-[clamp(0.92rem,1vw+0.42rem,1.18rem)] font-semibold leading-tight"
            >
              {{ splitMemberName(m.name).lastName }}
            </span>
            <span
              v-if="splitMemberName(m.name).firstName"
              class="block text-[clamp(0.72rem,1vw+0.18rem,0.98rem)] leading-tight"
              :class="m.id === selected ? 'text-blue-100' : 'text-slate-500'"
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

