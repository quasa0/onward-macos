// Independent renderer for the same public CDP inputs used by Codex's browser runtime.
// No dependency on OpenAI's private accessibility WASM.
export function renderAX(nodes, budget = 18000) {
  const lines = [], seen = new Set(); let size = 0;
  for (const node of nodes) {
    if (node.ignored) continue;
    const role = String(node.role?.value ?? "element");
    if (role === "InlineTextBox" || role === "generic" && !node.name?.value && !node.value?.value) continue;
    const properties = Object.fromEntries((node.properties ?? []).map(p => [p.name, p.value?.value]));
    if (properties.protected) continue;
    const name = String(node.name?.value ?? "").trim(), value = String(node.value?.value ?? "").trim();
    const text = [name, value && value !== name ? value : ""].filter(Boolean).join(" | ");
    if (!text) continue;
    const line = `${role}: ${text}${properties.focused ? " [focused]" : ""}${properties.selected ? " [selected]" : ""}`;
    if (seen.has(line)) continue;
    seen.add(line); size += line.length;
    if (size > budget) { lines.push("[Accessibility text truncated]"); break; }
    lines.push(line);
  }
  return lines.join("\n");
}

export function renderDOM(snapshot, budget = 6000) {
  const lines = [], seen = new Set(); let size = 0;
  for (const document of snapshot.documents ?? []) {
    const nodes = document.nodes ?? {};
    const values = nodes.nodeValue ?? [];
    const types = nodes.nodeType ?? [];
    const parents = nodes.parentIndex ?? [];
    const names = nodes.nodeName ?? [];
    for (let i = 0; i < values.length; i++) {
      if (types[i] !== 3) continue;
      const parentName = snapshot.strings?.[names[parents[i]]];
      if (["SCRIPT", "STYLE", "NOSCRIPT"].includes(parentName)) continue;
      const value = String(snapshot.strings?.[values[i]] ?? "").trim();
      if (!value || seen.has(value)) continue;
      seen.add(value); size += value.length;
      if (size > budget) return lines.join("\n") + "\n[DOM text truncated]";
      lines.push(value);
    }
  }
  return lines.join("\n");
}
