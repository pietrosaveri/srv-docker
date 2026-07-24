const BASE = "/api/admin";

async function request(path, options = {}) {
  const res = await fetch(BASE + path, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options,
  });

  let data = null;
  try {
    data = await res.json();
  } catch {
    // no JSON body (e.g. 204)
  }

  if (!res.ok) {
    throw new Error((data && data.error) || `request failed (${res.status})`);
  }
  return data;
}

export const api = {
  status: () => request("/status"),
  setup: (password) => request("/setup", { method: "POST", body: JSON.stringify({ password }) }),
  login: (password) => request("/login", { method: "POST", body: JSON.stringify({ password }) }),
  logout: () => request("/logout", { method: "POST" }),

  listLinks: () => request("/links"),
  createLink: (payload) => request("/links", { method: "POST", body: JSON.stringify(payload) }),
  setLinkActive: (id, active) => request(`/links/${id}`, { method: "PATCH", body: JSON.stringify({ active }) }),
  deleteLink: (id) => request(`/links/${id}`, { method: "DELETE" }),

  listUploads: (params = {}) => {
    const qs = new URLSearchParams(
      Object.fromEntries(Object.entries(params).filter(([, v]) => v !== undefined && v !== null)),
    ).toString();
    return request(`/uploads${qs ? "?" + qs : ""}`);
  },
  deleteUpload: (id) => request(`/uploads/${id}`, { method: "DELETE" }),
};
