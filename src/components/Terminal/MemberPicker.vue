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
const searchTerm = ref("");
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
  const query = searchTerm.value.trim().toLocaleLowerCase("de-DE");

  const sorted = [...store.members].sort((a, b) => {
    const aLast = a.last_booking_at ? new Date(a.last_booking_at).getTime() : 0;
    const bLast = b.last_booking_at ? new Date(b.last_booking_at).getTime() : 0;
    const aInactive = now - aLast > THIRTY;
    const bInactive = now - bLast > THIRTY;

    if (aInactive !== bInactive) return aInactive ? 1 : -1;
    return a.name.localeCompare(b.name, "de");
  });

  return sorted.filter((m) => {
    const matchesLetter = !selectedLetter.value || getLastNameInitial(m.name) === selectedLetter.value;
    if (!matchesLetter) return false;
    if (!query) return true;
    return String(m.name).toLocaleLowerCase("de-DE").includes(query);
  });
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
  <div class="member-picker flex h-full w-full flex-col overflow-hidden">
    <div class="border-b border-white/10 px-3 py-3">
      <div class="flex flex-col gap-3 lg:flex-row lg:items-center">
        <div class="w-full lg:max-w-sm">
          <label class="sr-only" for="member-search">Mitglied suchen</label>
          <input
            id="member-search"
            v-model="searchTerm"
            type="search"
            autocomplete="off"
            placeholder="Mitglied suchen"
            class="w-full rounded-xl border border-white/10 bg-white/8 px-3 py-2.5 text-sm text-white placeholder:text-slate-400 focus:border-cyan-300/40 focus:outline-none"
          />
        </div>

        <div class="flex overflow-x-auto gap-2 pb-1">
        <button
          v-for="ch in alphabet"
          :key="ch"
          @click="availableLetters.includes(ch) && toggleLetter(ch)"
          :disabled="!availableLetters.includes(ch)"
          class="flex h-10 min-w-[2.5rem] items-center justify-center rounded-xl border px-3 text-sm font-semibold transition"
          :class="[
            selectedLetter === ch
              ? 'border-cyan-300/40 bg-cyan-400/20 text-white shadow-[0_10px_30px_rgba(34,211,238,0.16)]'
              : availableLetters.includes(ch)
              ? 'border-white/10 bg-white/6 text-slate-200 hover:border-cyan-300/30 hover:bg-white/10'
              : 'cursor-not-allowed border-white/5 bg-white/4 text-slate-500',
          ]"
        >
          {{ ch }}
        </button>
        </div>
      </div>
    </div>

    <div class="flex-1 min-h-0 overflow-y-auto px-3 py-3">
      <div class="grid content-start grid-cols-3 gap-2 sm:grid-cols-4 md:grid-cols-5 lg:grid-cols-6">
      <template v-for="(m, i) in filteredMembers" :key="m.id">
        <div
          v-if="i > 0 && isInactive(m) && !isInactive(filteredMembers[i - 1])"
          class="col-span-full my-2 border-t border-dashed border-white/12 py-2 text-center text-xs text-slate-400"
        >
          Länger als 30 Tage nicht gebucht ↓
        </div>

        <button
          @click="selectMember(m.id)"
          class="member-card group flex h-20 flex-col justify-center rounded-xl border px-3 py-3 text-center transition"
          :class="[
            m.is_guest
              ? 'border-amber-300/25 bg-amber-400/12 text-amber-50 hover:bg-amber-400/18'
              : m.id === selected
              ? 'border-cyan-300/35 bg-cyan-400/16 text-white scale-[1.01]'
              : bookedTodayIds.has(m.id)
              ? 'border-emerald-300/25 bg-emerald-400/12 text-emerald-50 hover:bg-emerald-400/18'
              : 'border-white/10 bg-white/6 text-slate-100 hover:border-white/20 hover:bg-white/10',
          ]"
        >
          <span class="block px-1 whitespace-normal break-words">
            <span
              class="block text-[clamp(0.9rem,1vw+0.4rem,1.2rem)] font-semibold leading-tight text-white"
            >
              {{ splitMemberName(m.name).lastName }}
            </span>
            <span
              v-if="splitMemberName(m.name).firstName"
              class="block text-[clamp(0.7rem,0.8vw+0.2rem,0.95rem)] leading-tight text-slate-300/80"
            >
              {{ splitMemberName(m.name).firstName }}
            </span>
          </span>
        </button>
      </template>
      </div>

      <p
        v-if="!filteredMembers.length"
        class="col-span-full py-8 text-center text-sm text-slate-400"
      >
        Kein Mitglied gefunden
      </p>
    </div>
  </div>
</template>

<style scoped>
.member-picker {
  background: rgba(2, 6, 23, 0.14);
}

.member-card {
  box-shadow: 0 10px 28px rgba(15, 23, 42, 0.14);
  backdrop-filter: blur(10px);
}

.member-card:hover {
  transform: translateY(-1px);
}

::-webkit-scrollbar {
  height: 4px;
  width: 6px;
}
::-webkit-scrollbar-thumb {
  background-color: rgba(148, 163, 184, 0.35);
  border-radius: 3px;
}
</style>
