const storageKey = "remote-codex-bridge-chat-ui";
const apiBase = window.location.protocol === "file:" ? "http://127.0.0.1:8765" : window.location.origin;

const defaultConfig = {
  host: "your-remote-host",
  port: "22",
  user: "your-user",
  remote_root: "/home/your-user/project",
  local_root: "remote",
};

const state = {
  activeProject: "default",
  projectSearch: "",
  sidebarCollapsed: false,
  settingsOpen: false,
  draft: "",
  attachments: [],
  dragActive: false,
  loading: false,
  serverConnected: false,
  codexAvailable: false,
  projects: {},
};

const el = {
  layout: document.querySelector(".layout"),
  toggleSidebar: document.querySelector("#toggle-sidebar"),
  newProject: document.querySelector("#new-project"),
  projectSearch: document.querySelector("#project-search"),
  projectList: document.querySelector("#project-list"),
  sidebarWorkspace: document.querySelector("#sidebar-workspace"),
  sidebarRemoteRoot: document.querySelector("#sidebar-remote-root"),
  activeProjectName: document.querySelector("#active-project-name"),
  serverStatus: document.querySelector("#server-status"),
  copyInitCommand: document.querySelector("#copy-init-command"),
  copyUseCommand: document.querySelector("#copy-use-command"),
  copyListCommand: document.querySelector("#copy-list-command"),
  toggleSettings: document.querySelector("#toggle-settings"),
  settingsPanel: document.querySelector("#settings-panel"),
  projectNameInput: document.querySelector("#project-name-input"),
  hostInput: document.querySelector("#host-input"),
  portInput: document.querySelector("#port-input"),
  userInput: document.querySelector("#user-input"),
  remoteRootInput: document.querySelector("#remote-root-input"),
  localRootInput: document.querySelector("#local-root-input"),
  yamlInput: document.querySelector("#yaml-input"),
  importYaml: document.querySelector("#import-yaml"),
  saveProject: document.querySelector("#save-project"),
  chatThread: document.querySelector("#chat-thread"),
  composerBox: document.querySelector("#composer-box"),
  dropHint: document.querySelector("#drop-hint"),
  attachmentList: document.querySelector("#attachment-list"),
  fileInput: document.querySelector("#file-input"),
  attachFile: document.querySelector("#attach-file"),
  chatInput: document.querySelector("#chat-input"),
  sendMessage: document.querySelector("#send-message"),
  messageTemplate: document.querySelector("#message-template"),
};

function loadState() {
  const saved = localStorage.getItem(storageKey);
  if (!saved) {
    return;
  }

  try {
    const parsed = JSON.parse(saved);
    state.activeProject = parsed.activeProject || state.activeProject;
    state.projectSearch = parsed.projectSearch || "";
    state.sidebarCollapsed = Boolean(parsed.sidebarCollapsed);
    state.settingsOpen = Boolean(parsed.settingsOpen);
    state.draft = parsed.draft || "";
    state.projects = parsed.projects || {};
  } catch (_error) {
    localStorage.removeItem(storageKey);
  }
}

function persistState() {
  localStorage.setItem(
    storageKey,
    JSON.stringify({
      activeProject: state.activeProject,
      projectSearch: state.projectSearch,
      sidebarCollapsed: state.sidebarCollapsed,
      settingsOpen: state.settingsOpen,
      draft: state.draft,
      projects: state.projects,
    }),
  );
}

function sanitizeProjectName(value) {
  const trimmed = value.trim();
  if (!trimmed) {
    return "default";
  }
  return trimmed.replace(/[^A-Za-z0-9._-]/g, "-");
}

function ensureProject(name) {
  if (!state.projects[name]) {
    state.projects[name] = {
      config: { ...defaultConfig },
      messages: [],
    };
  }
}

function activeProject() {
  ensureProject(state.activeProject);
  return state.projects[state.activeProject];
}

function projectConfig(name = state.activeProject) {
  ensureProject(name);
  return state.projects[name].config;
}

function workspaceRoot(name = state.activeProject) {
  return `projects/${name}`;
}

function workspaceLocalRoot(name = state.activeProject) {
  const config = projectConfig(name);
  return `${workspaceRoot(name)}/${config.local_root || "remote"}/`;
}

function commandPrefix(name = state.activeProject) {
  return `./scripts/ab.sh --project ${name} `;
}

function yamlFromConfig(config) {
  return [
    `host: "${config.host}"`,
    `port: ${config.port}`,
    `user: "${config.user}"`,
    `remote_root: "${config.remote_root}"`,
    `local_root: "${config.local_root}"`,
  ].join("\n");
}

function parseYamlConfig(text) {
  const next = {};

  text.split(/\r?\n/).forEach((line) => {
    const trimmed = line.replace(/#.*/, "").trim();
    if (!trimmed || !trimmed.includes(":")) {
      return;
    }

    const index = trimmed.indexOf(":");
    const key = trimmed.slice(0, index).trim();
    let value = trimmed.slice(index + 1).trim();
    value = value.replace(/^['"]|['"]$/g, "");

    if (["host", "port", "user", "remote_root", "local_root"].includes(key)) {
      next[key] = value;
    }
  });

  state.projects[state.activeProject].config = {
    ...projectConfig(),
    ...next,
  };
}

function copyText(text, button) {
  navigator.clipboard.writeText(text).then(() => {
    const original = button.textContent;
    button.textContent = "コピー済み";
    window.setTimeout(() => {
      button.textContent = original;
    }, 1200);
  }).catch(() => {
    window.alert("コピーに失敗しました。");
  });
}

function escapeHtml(value) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function formatBytes(size) {
  if (size < 1024) {
    return `${size} B`;
  }
  if (size < 1024 * 1024) {
    return `${(size / 1024).toFixed(1)} KB`;
  }
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}

function isTextLikeFile(file) {
  if (file.type.startsWith("text/")) {
    return true;
  }

  return /\.(txt|md|markdown|py|js|ts|tsx|jsx|json|yml|yaml|toml|ini|cfg|conf|sh|bash|zsh|rb|go|rs|java|kt|swift|c|cc|cpp|h|hpp|css|scss|html|xml|csv|log)$/i.test(file.name);
}

async function fileToAttachment(file) {
  const attachment = {
    id: `${file.name}-${file.size}-${file.lastModified}`,
    name: file.name,
    size: file.size,
    type: file.type || "application/octet-stream",
    kind: "binary",
    truncated: false,
  };

  if (!isTextLikeFile(file)) {
    return attachment;
  }

  let content = await file.text();
  if (content.length > 120000) {
    content = `${content.slice(0, 120000)}\n\n[truncated]`;
    attachment.truncated = true;
  }

  return {
    ...attachment,
    kind: "text",
    content,
  };
}

async function addFiles(files) {
  const nextFiles = Array.from(files).slice(0, 8);
  if (!nextFiles.length) {
    return;
  }

  const attachments = await Promise.all(nextFiles.map(fileToAttachment));
  const merged = [...state.attachments];

  attachments.forEach((attachment) => {
    if (!merged.some((item) => item.id === attachment.id)) {
      merged.push(attachment);
    }
  });

  state.attachments = merged.slice(0, 8);
  renderAttachments();
}

function removeAttachment(id) {
  state.attachments = state.attachments.filter((attachment) => attachment.id !== id);
  renderAttachments();
}

function extractCommands(text) {
  const commands = new Set();
  const codeBlockRegex = /```(?:bash|sh)?\n([\s\S]*?)```/g;
  let match;

  while ((match = codeBlockRegex.exec(text)) !== null) {
    match[1]
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line.startsWith("./scripts/ab.sh"))
      .forEach((line) => commands.add(line));
  }

  text
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.startsWith("./scripts/ab.sh"))
    .forEach((line) => commands.add(line));

  return [...commands];
}

function buildInitCommand(name = state.activeProject) {
  return `./scripts/ab.sh project init ${name}`;
}

function buildUseCommand(name = state.activeProject) {
  return `./scripts/ab.sh project use ${name}`;
}

function buildStatusCommand(name = state.activeProject) {
  return `${commandPrefix(name)}status`;
}

async function apiFetch(path, options = {}) {
  const response = await fetch(`${apiBase}${path}`, {
    headers: {
      "Content-Type": "application/json",
      ...(options.headers || {}),
    },
    ...options,
  });

  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.details || payload.message || "Request failed");
  }
  return payload;
}

async function loadProjectsFromServer() {
  const payload = await apiFetch("/api/projects");
  state.serverConnected = true;
  state.codexAvailable = Boolean(payload.codex_available);

  (payload.projects || []).forEach((project) => {
    ensureProject(project.name);
    state.projects[project.name].config = {
      ...defaultConfig,
      ...(project.config || {}),
    };
  });

  if (payload.current) {
    state.activeProject = payload.current;
  }

  ensureProject(state.activeProject);

  if (!activeProject().messages.length) {
    activeProject().messages.push({
      role: "assistant",
      content:
        "Codex UI サーバーに接続しました。\n\nCommand+Enter で送信すると、ローカルの Codex CLI に問い合わせます。",
      commands: [
        buildInitCommand(),
        buildUseCommand(),
        buildStatusCommand(),
      ],
    });
  }

  persistState();
}

async function saveProjectToServer() {
  const payload = await apiFetch("/api/projects", {
    method: "POST",
    body: JSON.stringify({
      name: state.activeProject,
      config: projectConfig(),
    }),
  });

  const project = payload.project;
  ensureProject(project.name);
  state.projects[project.name].config = {
    ...defaultConfig,
    ...(project.config || {}),
  };
  state.activeProject = project.name;
  persistState();
}

function createMessageElement(message) {
  const fragment = el.messageTemplate.content.cloneNode(true);
  const messageEl = fragment.querySelector(".message");
  const avatarEl = fragment.querySelector(".message__avatar");
  const roleEl = fragment.querySelector(".message__role");
  const bodyEl = fragment.querySelector(".message__body");

  messageEl.classList.add(`message--${message.role}`);
  if (message.pending) {
    messageEl.classList.add("message--pending");
  }
  avatarEl.textContent = message.role === "user" ? "U" : "C";
  roleEl.textContent = message.role === "user" ? "You" : "Codex Bridge";

  const textBlock = document.createElement("div");
  textBlock.className = "message__text";

  if (message.pending) {
    textBlock.innerHTML = "<p>Codex CLI に問い合わせています...</p>";
  } else {
    textBlock.innerHTML = message.content
      .split("\n")
      .map((line) => {
        const escaped = escapeHtml(line);
        return `<p>${escaped.replace(/`([^`]+)`/g, "<code>$1</code>").replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")}</p>`;
      })
      .join("");
  }
  bodyEl.appendChild(textBlock);

  if (message.attachments && message.attachments.length && !message.pending) {
    const attachmentList = document.createElement("div");
    attachmentList.className = "message__attachments";

    message.attachments.forEach((attachment) => {
      const item = document.createElement("div");
      item.className = "attachment-pill";
      item.innerHTML = `
        <strong>${escapeHtml(attachment.name)}</strong>
        <span>${attachment.kind === "text" ? "text" : "binary"} · ${formatBytes(attachment.size || 0)}</span>
      `;
      attachmentList.appendChild(item);
    });

    bodyEl.appendChild(attachmentList);
  }

  if (message.commands && message.commands.length && !message.pending) {
    const commandList = document.createElement("div");
    commandList.className = "message__commands";

    message.commands.forEach((command) => {
      const commandCard = document.createElement("div");
      commandCard.className = "command-card";

      const pre = document.createElement("pre");
      pre.textContent = command;
      commandCard.appendChild(pre);

      const button = document.createElement("button");
      button.type = "button";
      button.className = "command-card__copy";
      button.textContent = "コピー";
      button.addEventListener("click", () => copyText(command, button));
      commandCard.appendChild(button);
      commandList.appendChild(commandCard);
    });

    bodyEl.appendChild(commandList);
  }

  return fragment;
}

function renderProjectList() {
  const keyword = state.projectSearch.trim().toLowerCase();
  el.projectList.innerHTML = "";

  Object.keys(state.projects)
    .sort()
    .filter((name) => !keyword || name.toLowerCase().includes(keyword))
    .forEach((name) => {
      const project = state.projects[name];
      const button = document.createElement("button");
      button.type = "button";
      button.className = "project-item";
      button.dataset.short = name.slice(0, 1).toUpperCase();
      if (name === state.activeProject) {
        button.classList.add("is-active");
      }

      const preview = (project.messages[project.messages.length - 1]?.content || "まだ会話がありません")
        .replace(/\n/g, " ")
        .slice(0, 42);

      button.innerHTML = `
        <strong>${name}</strong>
        <span>${preview}</span>
      `;

      button.addEventListener("click", () => {
        state.activeProject = name;
        state.draft = "";
        persistState();
        syncInputs();
        render();
      });

      el.projectList.appendChild(button);
    });
}

function renderChat() {
  el.chatThread.innerHTML = "";
  const messages = activeProject().messages;

  messages.forEach((message) => {
    el.chatThread.appendChild(createMessageElement(message));
  });

  el.chatThread.scrollTop = el.chatThread.scrollHeight;
}

function renderAttachments() {
  el.attachmentList.innerHTML = "";
  el.composerBox.classList.toggle("is-drag-active", state.dragActive);
  el.dropHint.classList.toggle("is-hidden", !state.dragActive);

  state.attachments.forEach((attachment) => {
    const item = document.createElement("div");
    item.className = "attachment-chip";
    item.innerHTML = `
      <div class="attachment-chip__body">
        <strong>${escapeHtml(attachment.name)}</strong>
        <span>${attachment.kind === "text" ? "text" : "binary"} · ${formatBytes(attachment.size)}</span>
      </div>
    `;

    const button = document.createElement("button");
    button.type = "button";
    button.className = "attachment-chip__remove";
    button.textContent = "×";
    button.addEventListener("click", () => removeAttachment(attachment.id));
    item.appendChild(button);
    el.attachmentList.appendChild(item);
  });
}

function syncInputs() {
  const config = projectConfig();
  el.projectNameInput.value = state.activeProject;
  el.hostInput.value = config.host;
  el.portInput.value = config.port;
  el.userInput.value = config.user;
  el.remoteRootInput.value = config.remote_root;
  el.localRootInput.value = config.local_root;
  el.yamlInput.value = yamlFromConfig(config);
  el.chatInput.value = state.draft;
  el.chatInput.style.height = "auto";
  el.chatInput.style.height = `${Math.min(el.chatInput.scrollHeight, 180)}px`;
  renderAttachments();
}

function renderMeta() {
  const config = projectConfig();
  el.layout.classList.toggle("sidebar-collapsed", state.sidebarCollapsed);
  el.settingsPanel.classList.toggle("is-hidden", !state.settingsOpen);
  el.activeProjectName.textContent = state.activeProject;
  el.sidebarWorkspace.textContent = workspaceRoot();
  el.sidebarRemoteRoot.textContent = workspaceLocalRoot();
  el.serverStatus.textContent = state.serverConnected
    ? (state.codexAvailable ? "Codex Connected" : "Server Ready")
    : (window.location.protocol === "file:" ? "Direct Open Mode" : "Server Offline");
  el.serverStatus.className = `status-pill ${state.serverConnected ? "is-online" : "is-offline"}`;
  el.sendMessage.disabled = state.loading || !state.serverConnected;
  el.sendMessage.textContent = state.loading ? "…" : "↑";
}

function render() {
  renderProjectList();
  renderMeta();
  renderChat();
}

function updateActiveProjectConfig() {
  state.projects[state.activeProject].config = {
    host: el.hostInput.value.trim() || defaultConfig.host,
    port: el.portInput.value.trim() || defaultConfig.port,
    user: el.userInput.value.trim() || defaultConfig.user,
    remote_root: el.remoteRootInput.value.trim() || defaultConfig.remote_root,
    local_root: el.localRootInput.value.trim() || defaultConfig.local_root,
  };
  el.yamlInput.value = yamlFromConfig(projectConfig());
}

async function submitMessage() {
  const text = el.chatInput.value.trim();
  if ((!text && !state.attachments.length) || state.loading) {
    return;
  }

  const userMessage = {
    role: "user",
    content: text || "添付ファイルを追加しました。",
    attachments: [...state.attachments],
  };
  activeProject().messages.push(userMessage);
  const pendingMessage = {
    role: "assistant",
    content: "",
    pending: true,
  };
  activeProject().messages.push(pendingMessage);
  state.draft = "";
  state.loading = true;
  persistState();
  syncInputs();
  render();

  try {
    const payload = await apiFetch("/api/chat", {
      method: "POST",
      body: JSON.stringify({
        project: state.activeProject,
        message: text,
        messages: activeProject().messages.filter((item) => !item.pending),
      }),
    });

    activeProject().messages[activeProject().messages.length - 1] = {
      role: "assistant",
      content: payload.message || "Codex から空の応答が返りました。",
      commands: extractCommands(payload.message || ""),
    };
    state.serverConnected = true;
  } catch (error) {
    activeProject().messages[activeProject().messages.length - 1] = {
      role: "assistant",
      content: `Codex CLI への問い合わせに失敗しました。\n\n${error.message}\n\n現在の API 接続先は \`${apiBase}\` です。\nサーバーは \`./scripts/ui-serve.sh\` で起動してください。`,
      commands: [
        "./scripts/ui-serve.sh",
        "http://127.0.0.1:8765",
      ],
    };
    state.serverConnected = false;
  } finally {
    state.attachments = [];
    state.dragActive = false;
    state.loading = false;
    persistState();
    render();
  }
}

async function createProject() {
  const baseName = sanitizeProjectName(window.prompt("新しいプロジェクト名を入力してください", "client-a") || "");
  if (!baseName) {
    return;
  }

  ensureProject(baseName);
  state.activeProject = baseName;
  state.settingsOpen = true;
  activeProject().messages.push({
    role: "assistant",
    content: `**${baseName}** の workspace を用意します。\n\n保存すると \`projects/${baseName}/config.yml\` を作成します。`,
    commands: [
      buildInitCommand(baseName),
      buildUseCommand(baseName),
      buildStatusCommand(baseName),
    ],
  });

  try {
    await saveProjectToServer();
    state.serverConnected = true;
  } catch (_error) {
    state.serverConnected = false;
  }

  persistState();
  syncInputs();
  render();
}

async function renameAndSaveProject() {
  const nextName = sanitizeProjectName(el.projectNameInput.value);
  if (nextName !== state.activeProject) {
    if (state.projects[nextName]) {
      window.alert("そのプロジェクト名は既に使われています。");
      el.projectNameInput.value = state.activeProject;
      return;
    }
    state.projects[nextName] = state.projects[state.activeProject];
    delete state.projects[state.activeProject];
    state.activeProject = nextName;
  }

  updateActiveProjectConfig();
  await saveProjectToServer();
  persistState();
  syncInputs();
  render();
}

function bindEvents() {
  el.toggleSidebar.addEventListener("click", () => {
    state.sidebarCollapsed = !state.sidebarCollapsed;
    persistState();
    renderMeta();
  });

  el.newProject.addEventListener("click", createProject);

  el.projectSearch.addEventListener("input", (event) => {
    state.projectSearch = event.target.value;
    persistState();
    renderProjectList();
  });

  el.copyListCommand.addEventListener("click", () => {
    copyText("./scripts/ab.sh project list", el.copyListCommand);
  });

  el.copyInitCommand.addEventListener("click", () => {
    copyText(buildInitCommand(), el.copyInitCommand);
  });

  el.copyUseCommand.addEventListener("click", () => {
    copyText(buildUseCommand(), el.copyUseCommand);
  });

  el.toggleSettings.addEventListener("click", () => {
    state.settingsOpen = !state.settingsOpen;
    persistState();
    renderMeta();
  });

  [el.hostInput, el.portInput, el.userInput, el.remoteRootInput, el.localRootInput].forEach((input) => {
    input.addEventListener("input", () => {
      updateActiveProjectConfig();
      persistState();
      renderMeta();
    });
  });

  el.importYaml.addEventListener("click", () => {
    parseYamlConfig(el.yamlInput.value);
    persistState();
    syncInputs();
    renderMeta();
  });

  el.saveProject.addEventListener("click", async () => {
    try {
      await renameAndSaveProject();
      state.serverConnected = true;
    } catch (error) {
      window.alert(`保存に失敗しました: ${error.message}`);
      state.serverConnected = false;
    }
    render();
  });

  el.chatInput.addEventListener("input", (event) => {
    state.draft = event.target.value;
    event.target.style.height = "auto";
    event.target.style.height = `${Math.min(event.target.scrollHeight, 180)}px`;
    persistState();
  });

  el.chatInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      submitMessage();
    }
  });

  el.attachFile.addEventListener("click", () => {
    el.fileInput.click();
  });

  el.fileInput.addEventListener("change", async (event) => {
    await addFiles(event.target.files || []);
    event.target.value = "";
  });

  ["dragenter", "dragover"].forEach((name) => {
    el.composerBox.addEventListener(name, (event) => {
      event.preventDefault();
      state.dragActive = true;
      renderAttachments();
    });
  });

  ["dragleave", "drop"].forEach((name) => {
    el.composerBox.addEventListener(name, (event) => {
      event.preventDefault();
      if (name === "drop") {
        state.dragActive = false;
      } else if (!el.composerBox.contains(event.relatedTarget)) {
        state.dragActive = false;
      }
      renderAttachments();
    });
  });

  el.composerBox.addEventListener("drop", async (event) => {
    const files = event.dataTransfer?.files;
    if (files?.length) {
      await addFiles(files);
    }
  });

  el.sendMessage.addEventListener("click", submitMessage);
}

async function initialize() {
  loadState();
  ensureProject(state.activeProject);
  bindEvents();
  syncInputs();
  render();

  try {
    await loadProjectsFromServer();
  } catch (_error) {
    state.serverConnected = false;
    if (!activeProject().messages.length) {
      activeProject().messages.push({
        role: "assistant",
        content:
          `UI サーバーに接続できません。\n\n現在の API 接続先は \`${apiBase}\` です。\n\`./scripts/ui-serve.sh\` を起動してから \`http://127.0.0.1:8765\` を開いてください。`,
        commands: [
          "./scripts/ui-serve.sh",
          "http://127.0.0.1:8765",
        ],
      });
    }
  }

  persistState();
  syncInputs();
  render();
}

initialize();
