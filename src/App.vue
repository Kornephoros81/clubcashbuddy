<script setup lang="ts">
import ToastContainer from "@/components/ToastContainer.vue";
import { provide, ref } from "vue";

const toastRef = ref<InstanceType<typeof ToastContainer> | null>(null);
provide("toast", toastRef);
</script>

<template>
  <router-view />
  <ToastContainer ref="toastRef" />
</template>
