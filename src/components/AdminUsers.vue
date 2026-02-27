<script setup lang="ts">
import { onMounted, ref } from "vue";
import { useToast } from "@/composables/useToast";
import { adminRpc } from "@/lib/adminApi";

type AppUserRow = {
  id: string;
  username: string;
  role: string;
  is_admin: boolean;
  active: boolean;
  created_at: string;
  last_login_at: string | null;
  passwordDraft?: string;
  saving?: boolean;
};

const { show: showToast } = useToast();

const loading = ref(false);
const creating = ref(false);
const users = ref<AppUserRow[]>([]);

const newUsername = ref("");
const newPassword = ref("");
const newIsAdmin = ref(true);
const newActive = ref(true);

async function loadUsers() {
  loading.value = true;
  try {
    const data = await adminRpc("list_app_users");
    users.value = ((data as any[]) ?? []).map((u: any) => ({
      id: u.id,
      username: String(u.username ?? ""),
      role: String(u.role ?? "operator"),
      is_admin: Boolean(u.is_admin),
      active: Boolean(u.active),
      created_at: String(u.created_at ?? ""),
      last_login_at: u.last_login_at ?? null,
      passwordDraft: "",
      saving: false,
    }));
  } catch (err) {
    console.error("[AdminUsers.loadUsers]", err);
    showToast("⚠️ Benutzer konnten nicht geladen werden");
  } finally {
    loading.value = false;
  }
}

async function createUser() {
  if (!newUsername.value.trim()) {
    showToast("⚠️ Benutzername fehlt");
    return;
  }
  if (newPassword.value.trim().length < 4) {
    showToast("⚠️ Passwort muss mindestens 4 Zeichen haben");
    return;
  }

  creating.value = true;
  try {
    await adminRpc("create_app_user", {
      username: newUsername.value.trim(),
      password: newPassword.value.trim(),
      is_admin: newIsAdmin.value,
      active: newActive.value,
    });
    newUsername.value = "";
    newPassword.value = "";
    newIsAdmin.value = true;
    newActive.value = true;
    await loadUsers();
    showToast("✅ Benutzer angelegt");
  } catch (err: any) {
    console.error("[AdminUsers.createUser]", err);
    showToast(`⚠️ Anlegen fehlgeschlagen: ${String(err?.message ?? "Unbekannter Fehler")}`);
  } finally {
    creating.value = false;
  }
}

async function saveUser(user: AppUserRow) {
  user.saving = true;
  try {
    await adminRpc("update_app_user", {
      user_id: user.id,
      username: user.username.trim(),
      password: user.passwordDraft?.trim() || null,
      is_admin: user.is_admin,
      active: user.active,
    });
    user.passwordDraft = "";
    await loadUsers();
    showToast(`✅ ${user.username} gespeichert`);
  } catch (err: any) {
    console.error("[AdminUsers.saveUser]", err);
    showToast(`⚠️ Speichern fehlgeschlagen: ${String(err?.message ?? "Unbekannter Fehler")}`);
  } finally {
    user.saving = false;
  }
}

onMounted(loadUsers);
</script>

<template>
  <div class="space-y-6">
    <div class="flex justify-between items-center">
      <h2 class="text-xl font-semibold text-primary">👤 Admin-Benutzer</h2>
      <RouterLink to="/admin/dashboard" class="text-sm text-gray-500 hover:text-primary underline">
        ← Zurück zum Dashboard
      </RouterLink>
    </div>

    <div class="bg-white rounded-2xl shadow border border-gray-200 p-5 space-y-4">
      <h3 class="font-semibold text-gray-800">Neuen Benutzer anlegen</h3>
      <div class="flex flex-wrap gap-3 items-end">
        <div>
          <label class="block text-sm font-medium text-gray-600 mb-1">Benutzername</label>
          <input
            v-model="newUsername"
            type="text"
            class="border rounded-md px-3 py-2 text-sm min-w-[220px]"
            placeholder="z. B. admin2"
          />
        </div>
        <div>
          <label class="block text-sm font-medium text-gray-600 mb-1">Passwort</label>
          <input
            v-model="newPassword"
            type="password"
            class="border rounded-md px-3 py-2 text-sm min-w-[220px]"
            placeholder="mind. 4 Zeichen"
          />
        </div>
        <label class="inline-flex items-center gap-2 text-sm text-gray-700">
          <input v-model="newIsAdmin" type="checkbox" class="accent-primary" />
          Admin
        </label>
        <label class="inline-flex items-center gap-2 text-sm text-gray-700">
          <input v-model="newActive" type="checkbox" class="accent-primary" />
          Aktiv
        </label>
        <button
          @click="createUser"
          :disabled="creating"
          class="bg-primary text-white px-4 py-2 rounded-lg shadow hover:bg-primary/90 transition disabled:opacity-60"
        >
          {{ creating ? "Erstellt…" : "Benutzer anlegen" }}
        </button>
      </div>
    </div>

    <div class="bg-white rounded-2xl shadow overflow-x-auto border border-gray-200">
      <table class="min-w-full text-sm text-gray-700">
        <thead class="bg-primary/10 text-primary uppercase text-xs font-semibold">
          <tr>
            <th class="px-4 py-3 text-left">Benutzername</th>
            <th class="px-4 py-3 text-left">Rolle</th>
            <th class="px-4 py-3 text-center">Admin</th>
            <th class="px-4 py-3 text-center">Aktiv</th>
            <th class="px-4 py-3 text-left">Neues Passwort</th>
            <th class="px-4 py-3 text-left">Letzter Login</th>
            <th class="px-4 py-3 text-right">Aktion</th>
          </tr>
        </thead>
        <tbody>
          <tr v-if="loading">
            <td colspan="7" class="px-4 py-6 text-center text-gray-500">Lade Benutzer…</td>
          </tr>
          <tr
            v-for="user in users"
            :key="user.id"
            class="border-t hover:bg-primary/5 transition-colors"
          >
            <td class="px-4 py-2">
              <input v-model="user.username" type="text" class="border rounded-md px-2 py-1 w-full max-w-[240px]" />
            </td>
            <td class="px-4 py-2">{{ user.role }}</td>
            <td class="px-4 py-2 text-center">
              <input v-model="user.is_admin" type="checkbox" class="accent-primary" />
            </td>
            <td class="px-4 py-2 text-center">
              <input v-model="user.active" type="checkbox" class="accent-primary" />
            </td>
            <td class="px-4 py-2">
              <input
                v-model="user.passwordDraft"
                type="password"
                class="border rounded-md px-2 py-1 w-full max-w-[220px]"
                placeholder="leer = unverändert"
              />
            </td>
            <td class="px-4 py-2">
              {{ user.last_login_at ? new Date(user.last_login_at).toLocaleString("de-DE") : "-" }}
            </td>
            <td class="px-4 py-2 text-right">
              <button
                @click="saveUser(user)"
                :disabled="!!user.saving"
                class="bg-primary text-white px-3 py-1 rounded-md hover:bg-primary/90 transition disabled:opacity-60"
              >
                {{ user.saving ? "…" : "Speichern" }}
              </button>
            </td>
          </tr>
          <tr v-if="!loading && users.length === 0">
            <td colspan="7" class="px-4 py-6 text-center text-gray-400 italic">
              Keine Benutzer vorhanden
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
