<script setup lang="ts">
const emit = defineEmits<{
  (e: "select", start: Date, end: Date): void;
}>();

function startOf(d: Date): Date {
  const r = new Date(d);
  r.setHours(0, 0, 0, 0);
  return r;
}

function endOf(d: Date): Date {
  const r = new Date(d);
  r.setHours(23, 59, 59, 999);
  return r;
}

function selectToday() {
  const d = new Date();
  emit("select", startOf(d), endOf(d));
}

function selectThisWeek() {
  const d = new Date();
  const start = new Date(d);
  const day = d.getDay();
  const diff = day === 0 ? -6 : 1 - day; // Montag als Wochenstart
  start.setDate(d.getDate() + diff);
  emit("select", startOf(start), endOf(d));
}

function selectLastMonth() {
  const d = new Date();
  const start = new Date(d.getFullYear(), d.getMonth() - 1, 1);
  const end = new Date(d.getFullYear(), d.getMonth(), 0);
  emit("select", startOf(start), endOf(end));
}

function selectThisMonth() {
  const d = new Date();
  const start = new Date(d.getFullYear(), d.getMonth(), 1);
  emit("select", startOf(start), endOf(d));
}

function selectThisYear() {
  const d = new Date();
  const start = new Date(d.getFullYear(), 0, 1);
  emit("select", startOf(start), endOf(d));
}

function selectLast12Months() {
  const d = new Date();
  const start = new Date(d);
  start.setFullYear(d.getFullYear() - 1);
  emit("select", startOf(start), endOf(d));
}
</script>

<template>
  <div class="flex flex-wrap gap-1.5">
    <button
      type="button"
      @click="selectToday"
      class="rounded-xl border border-slate-300 bg-white px-3 py-1 text-xs font-semibold text-slate-700 hover:bg-slate-50 transition"
    >
      Heute
    </button>
    <button
      type="button"
      @click="selectThisWeek"
      class="rounded-xl border border-slate-300 bg-white px-3 py-1 text-xs font-semibold text-slate-700 hover:bg-slate-50 transition"
    >
      Diese Woche
    </button>
    <button
      type="button"
      @click="selectThisMonth"
      class="rounded-xl border border-slate-300 bg-white px-3 py-1 text-xs font-semibold text-slate-700 hover:bg-slate-50 transition"
    >
      Dieser Monat
    </button>
    <button
      type="button"
      @click="selectLastMonth"
      class="rounded-xl border border-slate-300 bg-white px-3 py-1 text-xs font-semibold text-slate-700 hover:bg-slate-50 transition"
    >
      Letzter Monat
    </button>
    <button
      type="button"
      @click="selectThisYear"
      class="rounded-xl border border-slate-300 bg-white px-3 py-1 text-xs font-semibold text-slate-700 hover:bg-slate-50 transition"
    >
      Aktuelles Jahr
    </button>
    <button
      type="button"
      @click="selectLast12Months"
      class="rounded-xl border border-slate-300 bg-white px-3 py-1 text-xs font-semibold text-slate-700 hover:bg-slate-50 transition"
    >
      Letzte 12 Monate
    </button>
  </div>
</template>
