const { ImapFlow } = require("imapflow");

// CORS headers
const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Content-Type": "application/json",
};

module.exports = async function handler(req, res) {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return res.status(200).json({});
  }

  if (req.method !== "POST") {
    return res.status(405).json({ error: "Method not allowed" });
  }

  const { email, password, action = "inbox", folder = "INBOX", page = 0, pageSize = 20, messageId } = req.body || {};

  if (!email || !password) {
    return res.status(400).json({ error: "email and password required" });
  }

  const client = new ImapFlow({
    host: "imaps.monlycee.net",
    port: 993,
    secure: true,
    auth: { user: email, pass: password },
    logger: false,
  });

  try {
    await client.connect();

    let result;

    switch (action) {
      case "inbox":
        result = await fetchInbox(client, folder, page, pageSize);
        break;
      case "message":
        result = await fetchMessage(client, folder, messageId);
        break;
      case "folders":
        result = await fetchFolders(client);
        break;
      case "unread":
        result = await fetchUnreadCount(client, folder);
        break;
      default:
        result = { error: "Unknown action" };
    }

    await client.logout();
    res.status(200).json(result);
  } catch (err) {
    try { await client.logout(); } catch {}

    if (err.authenticationFailed) {
      return res.status(401).json({ error: "Identifiants incorrects" });
    }

    console.error("IMAP error:", err.message);
    res.status(500).json({ error: err.message });
  }
};

async function fetchInbox(client, folder, page, pageSize) {
  const lock = await client.getMailboxLock(folder);

  try {
    const mailbox = client.mailbox;
    const total = mailbox.exists || 0;
    const unseen = mailbox.unseen || 0;

    // Calculate range (newest first)
    const end = Math.max(1, total - page * pageSize);
    const start = Math.max(1, end - pageSize + 1);

    const messages = [];

    if (total > 0) {
      const range = `${start}:${end}`;
      for await (const msg of client.fetch(range, {
        envelope: true,
        flags: true,
        bodyStructure: true,
      })) {
        messages.push({
          id: msg.uid,
          seq: msg.seq,
          subject: msg.envelope?.subject || "(sans objet)",
          from: formatAddress(msg.envelope?.from?.[0]),
          to: msg.envelope?.to?.map(formatAddress) || [],
          date: msg.envelope?.date?.toISOString() || null,
          unread: !msg.flags?.has("\\Seen"),
          flagged: msg.flags?.has("\\Flagged") || false,
          hasAttachment: hasAttachments(msg.bodyStructure),
        });
      }
    }

    // Reverse so newest is first
    messages.reverse();

    return { messages, total, unseen, page, pageSize };
  } finally {
    lock.release();
  }
}

async function fetchMessage(client, folder, uid) {
  const lock = await client.getMailboxLock(folder);

  try {
    const msg = await client.fetchOne(String(uid), {
      envelope: true,
      flags: true,
      bodyStructure: true,
      source: true,
      uid: true,
    }, { uid: true });

    // Mark as seen
    await client.messageFlagsAdd(String(uid), ["\\Seen"], { uid: true });

    // Extract text body
    let body = "";
    try {
      const textPart = await client.download(String(uid), "1", { uid: true });
      if (textPart) {
        const chunks = [];
        for await (const chunk of textPart.content) {
          chunks.push(chunk);
        }
        body = Buffer.concat(chunks).toString("utf-8");
      }
    } catch {}

    return {
      id: msg.uid,
      subject: msg.envelope?.subject || "(sans objet)",
      from: formatAddress(msg.envelope?.from?.[0]),
      to: msg.envelope?.to?.map(formatAddress) || [],
      cc: msg.envelope?.cc?.map(formatAddress) || [],
      date: msg.envelope?.date?.toISOString() || null,
      body,
      unread: false,
      hasAttachment: hasAttachments(msg.bodyStructure),
    };
  } finally {
    lock.release();
  }
}

async function fetchFolders(client) {
  const folders = [];
  for await (const folder of client.listTree()) {
    folders.push({
      name: folder.name,
      path: folder.path,
      delimiter: folder.delimiter,
      children: folder.folders?.map((f) => ({ name: f.name, path: f.path })) || [],
    });
  }
  return { folders };
}

async function fetchUnreadCount(client, folder) {
  const status = await client.status(folder, { unseen: true, messages: true });
  return { unseen: status.unseen, total: status.messages };
}

function formatAddress(addr) {
  if (!addr) return "Inconnu";
  if (addr.name) return addr.name;
  return `${addr.address || ""}`;
}

function hasAttachments(bodyStructure) {
  if (!bodyStructure) return false;
  if (bodyStructure.disposition === "attachment") return true;
  if (bodyStructure.childNodes) {
    return bodyStructure.childNodes.some(hasAttachments);
  }
  return false;
}
