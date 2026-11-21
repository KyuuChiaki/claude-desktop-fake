"use strict";

const profilePicker = {
  profiles: [], active: "", selected: "", loaded: false, busy: false,
  reading: false, epoch: 0, checked: 0, revision: null, error: "", warning: "",
  editor: "", editing: null,
};

function profileAvailable() {
  return profilePicker.loaded && !profilePicker.error && !profilePicker.busy && !profilePicker.editor &&
    profilePicker.profiles.some((p) => p.id === $("proxy-profile").value);
}

function profileControls(connected, write) {
  const editing = Boolean(profilePicker.editor);
  const canEdit = write && profilePicker.loaded && !profilePicker.error && !profilePicker.busy && !editing;
  $("proxy-profile").disabled = !connected || !profilePicker.profiles.length || profilePicker.busy || editing || Boolean(profilePicker.error);
  $("profile-new").disabled = !canEdit;
  $("profile-rename").disabled = !canEdit || !$("proxy-profile").value;
  $("profile-import").disabled = !canEdit;
  $("profile-inputs").disabled = profilePicker.busy || !connected;
  $("profile-store").disabled = !write || profilePicker.busy || Boolean(profilePicker.error);
}

function renderProfilePicker(d, readSaved) {
  const list = profilePicker.profiles;
  const select = $("proxy-profile");
  const signature = JSON.stringify(list);
  if (select.dataset.signature !== signature) {
    select.replaceChildren(...list.map((p) => new Option(p.name + " · " + p.server, p.id)));
    select.dataset.signature = signature;
  }
  if (readSaved) profilePicker.selected = profilePicker.active || (!d.proxy.configured ? list[0]?.id : "") || "";
  const entry = list.find((p) => p.id === profilePicker.selected);
  select.value = entry?.id || "";
  let caption = list.length ? "选择代理配置" : "暂无代理配置";
  if (!profilePicker.loaded) caption = "正在读取…";
  if (profilePicker.error) caption = "配置列表不可用";
  put("profile-caption", profilePicker.error ? caption : entry?.name || caption);
  const text = [];
  if (entry) text.push("所选 " + entry.server + ":" + entry.port);
  if (d.proxy.readable) text.push(entry?.id === profilePicker.active ? "正在使用此配置" : "已部署 " + d.proxy.server + ":" + d.proxy.port);
  if (profilePicker.error || profilePicker.warning) text.push(profilePicker.error || profilePicker.warning);
  put("proxy-summary", text.join(" · "));
}

function loadProfileList(result) {
  profilePicker.profiles = result.profiles;
  profilePicker.active = result.activeId || "";
  profilePicker.warning = result.warning || "";
  profilePicker.error = "";
  profilePicker.loaded = true;
}

async function refreshProfiles(force = false) {
  if (!state.session || !state.snapshot || state.stopped || profilePicker.reading || profilePicker.busy) return;
  const revision = state.snapshot.proxyRevision;
  if (!force && revision === profilePicker.revision && Date.now() - profilePicker.checked < 8000) return;
  const epoch = profilePicker.epoch;
  profilePicker.reading = true;
  try {
    const result = await api("/api/profiles");
    if (epoch !== profilePicker.epoch) return;
    loadProfileList(result);
  } catch (error) {
    if (epoch !== profilePicker.epoch) return;
    profilePicker.error = error.message;
  } finally {
    profilePicker.reading = false;
    if (epoch === profilePicker.epoch) {
      profilePicker.revision = revision;
      profilePicker.checked = Date.now();
      renderSettings(state.snapshot);
      controls();
    }
  }
}

function profileApplied(id) {
  profilePicker.active = id;
  profilePicker.revision = null;
  profilePicker.epoch++;
}

function showProfileEditor(mode) {
  const form = $("profile-editor");
  form.reset();
  const selected = profilePicker.profiles.find((p) => p.id === $("proxy-profile").value);
  profilePicker.editor = mode;
  profilePicker.editing = mode === "rename" ? selected : null;
  form.hidden = !mode;
  $("proxy-fields").hidden = mode !== "new";
  for (const input of $("proxy-fields").querySelectorAll("input")) {
    input.disabled = mode !== "new";
    input.required = mode === "new" && input.id !== "proxy-short-id";
  }
  $("profile-name").value = profilePicker.editing?.name || "";
  $("profile-store").textContent = mode === "rename" ? "保存名称" : "保存到列表";
  controls();
  if (mode) $("profile-name").focus();
}

async function changeProfiles(path, payload, isRename = false) {
  if (profilePicker.busy || !state.update?.canManage) return;
  profilePicker.busy = true;
  profilePicker.epoch++;
  controls();
  feedback("catalog-feedback", path.endsWith("/import") ? "正在导入 YAML…" : "正在保存配置列表…");
  try {
    const result = await api(path, "POST", payload);
    loadProfileList(result);
    showProfileEditor("");
    if (!isRename && result.selected) {
      profilePicker.selected = result.selected;
      state.drafts.proxy.edits++;
      state.drafts.proxy.dirty = true;
      $("proxy-preview").hidden = true;
    }
    let message = isRename ? "名称已保存。" : "配置已保存到列表。";
    if (path.endsWith("/import")) {
      message = "已导入 " + result.imported + " 项。";
      if (result.skipped) message += "已跳过 " + result.skipped + " 个不支持的节点。";
    }
    feedback("catalog-feedback", message, "ok");
  } catch (error) {
    feedback("catalog-feedback", error.message, "error");
  } finally {
    profilePicker.busy = false;
    profilePicker.checked = 0;
    renderSettings(state.snapshot);
    controls();
  }
}

function wireProfiles() {
  $("profile-new").addEventListener("click", () => showProfileEditor("new"));
  $("profile-rename").addEventListener("click", () => showProfileEditor("rename"));
  $("profile-cancel").addEventListener("click", () => showProfileEditor(""));
  $("profile-editor").addEventListener("submit", (event) => {
    event.preventDefault();
    if ($("profile-store").disabled) return;
    const name = $("profile-name").value.trim();
    if (profilePicker.editor === "rename") {
      const current = profilePicker.editing;
      changeProfiles("/api/profiles/rename", {id:current.id, previousName:current.name, name}, true);
    } else {
      const values = {server:$("proxy-server").value.trim(), port:Number($("proxy-port").value),
        uuid:$("proxy-uuid").value.trim(), serverName:$("proxy-sni").value.trim(),
        publicKey:$("proxy-key").value.trim(), shortId:$("proxy-short-id").value.trim()};
      changeProfiles("/api/profiles", {name, values});
    }
  });
  $("profile-import").addEventListener("click", () => $("profile-file").click());
  $("profile-file").addEventListener("change", async () => {
    const file = $("profile-file").files[0];
    $("profile-file").value = "";
    if (!file) return;
    if (file.size === 0 || file.size > 1024 * 1024) {
      feedback("catalog-feedback", "请选择一个不超过 1 MiB 的 YAML 文件。", "error");
      return;
    }
    try { await changeProfiles("/api/profiles/import", await file.text()); }
    catch { feedback("catalog-feedback", "无法读取所选的 YAML 文件。", "error"); }
  });
}
