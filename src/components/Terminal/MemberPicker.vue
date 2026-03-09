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

const activeMembersCount = computed(() => store.members.filter((m) => !isInactive(m)).length);
const guestsCount = computed(() => store.members.filter((m) => m.is_guest).length);
const todayCount = computed(() => bookedTodayIds.value.size);

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
    <div class="border-b border-white/10 px-4 py-4 md:px-6">
      <div class="flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
        <div class="min-w-0">
          <div class="text-[0.68rem] uppercase tracking-[0.3em] text-cyan-100/55">Member Lounge</div>
          <div class="mt-2 terminal-picker-display text-2xl text-white md:text-4xl">
            Wer bucht gerade?
          </div>
        </div>

        <div class="w-full max-w-xl">
          <label class="sr-only" for="member-search">Mitglied suchen</label>
          <input
            id="member-search"
            v-model="searchTerm"
            type="search"
            autocomplete="off"
            placeholder="Mitglied suchen"
            class="w-full rounded-[1.2rem] border border-white/10 bg-white/8 px-4 py-3 text-base text-white placeholder:text-slate-400 focus:border-cyan-300/40 focus:outline-none"
          />
        </div>
      </div>

      <div class="mt-4 grid grid-cols-3 gap-2">
        <div class="member-stat-card">
          <div class="member-stat-label">Heute</div>
          <div class="member-stat-value">{{ todayCount }}</div>
        </div>
        <div class="member-stat-card">
          <div class="member-stat-label">Aktiv</div>
          <div class="member-stat-value">{{ activeMembersCount }}</div>
        </div>
        <div class="member-stat-card">
          <div class="member-stat-label">Gaeste</div>
          <div class="member-stat-value">{{ guestsCount }}</div>
        </div>
      </div>

      <div class="mt-4 flex overflow-x-auto gap-2 pb-1">
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

    <div
      class="flex-1 min-h-0 overflow-y-auto px-4 py-4 md:px-6"
    >
      <div
        class="grid content-start gap-3 sm:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4"
      >
      <template v-for="(m, i) in filteredMembers" :key="m.id">
        <div
          v-if="i > 0 && isInactive(m) && !isInactive(filteredMembers[i - 1])"
          class="col-span-full my-3 rounded-2xl border border-dashed border-white/12 bg-white/4 px-4 py-3 text-center text-sm text-slate-400"
        >
          Länger als 30 Tage nicht gebucht ↓
        </div>

        <button
          @click="selectMember(m.id)"
          class="member-card group flex min-h-[132px] flex-col justify-between rounded-[1.6rem] border p-4 text-left transition"
          :style="{ animationDelay: `${Math.min(i * 24, 320)}ms` }"
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
          <div class="flex items-start justify-between gap-3">
            <span
              class="flex h-11 w-11 items-center justify-center rounded-2xl border border-white/10 bg-black/10 text-sm font-semibold"
            >
              {{ splitMemberName(m.name).lastName.slice(0, 1) || "?" }}
            </span>
            <span
              class="rounded-full border px-2.5 py-1 text-[0.68rem] font-semibold uppercase tracking-[0.18em]"
              :class="
                m.is_guest
                  ? 'border-amber-200/30 bg-amber-50/10 text-amber-100'
                  : bookedTodayIds.has(m.id)
                  ? 'border-emerald-200/30 bg-emerald-50/10 text-emerald-100'
                  : 'border-white/10 bg-white/8 text-slate-300'
              "
            >
              {{ m.is_guest ? "Gast" : bookedTodayIds.has(m.id) ? "Heute" : "Mitglied" }}
            </span>
          </div>

          <span class="mt-4 block px-1 whitespace-normal break-words">
            <span
              class="block text-[clamp(1rem,0.9vw+0.7rem,1.38rem)] font-semibold leading-tight text-white"
            >
              {{ splitMemberName(m.name).lastName }}
            </span>
            <span
              v-if="splitMemberName(m.name).firstName"
              class="mt-1 block text-[clamp(0.8rem,0.8vw+0.25rem,1rem)] leading-tight text-slate-300/80"
            >
              {{ splitMemberName(m.name).firstName }}
            </span>
          </span>

          <div class="mt-4 flex items-center justify-between text-xs text-slate-400">
            <span>{{ getLastNameInitial(m.name) }}</span>
            <span>{{ isInactive(m) ? "Ruhend" : "Aktiv" }}</span>
          </div>
        </button>
      </template>
      </div>

      <p
        v-if="!filteredMembers.length"
        class="col-span-full rounded-2xl border border-dashed border-white/12 bg-white/4 py-10 text-center text-slate-400"
      >
        Kein Mitglied gefunden
      </p>
    </div>
  </div>
</template>

<style scoped>
.member-picker {
  background:
    linear-gradient(180deg, rgba(255, 255, 255, 0.03), transparent 26%),
    rgba(2, 6, 23, 0.18);
}

.terminal-picker-display {
  font-family: "Georgia", "Times New Roman", serif;
  line-height: 0.95;
  letter-spacing: -0.03em;
}

.member-card {
  box-shadow: 0 20px 60px rgba(15, 23, 42, 0.18);
  backdrop-filter: blur(14px);
  animation: member-card-rise 0.42s ease both;
}

.member-card:hover {
  transform: translateY(-2px);
}

.member-stat-card {
  border: 1px solid rgba(255, 255, 255, 0.08);
  background: rgba(255, 255, 255, 0.05);
  border-radius: 1.1rem;
  padding: 0.85rem 1rem;
  box-shadow: 0 16px 40px rgba(15, 23, 42, 0.14);
}

.member-stat-label {
  font-size: 0.68rem;
  text-transform: uppercase;
  letter-spacing: 0.22em;
  color: rgba(148, 163, 184, 0.9);
}

.member-stat-value {
  margin-top: 0.35rem;
  font-size: 1.35rem;
  font-weight: 600;
  color: white;
}

@keyframes member-card-rise {
  from {
    opacity: 0;
    transform: translateY(16px) scale(0.985);
  }
  to {
    opacity: 1;
    transform: translateY(0) scale(1);
  }
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
