import { useEffect, useState, useCallback } from "react";
import SetupPassword from "./SetupPassword.jsx";
import Login from "./Login.jsx";
import Dashboard from "./Dashboard.jsx";
import { api } from "./api.js";

export default function AdminApp() {
  const [status, setStatus] = useState(null);
  const [error, setError] = useState("");

  const refresh = useCallback(() => {
    api.status().then(setStatus).catch((e) => setError(e.message));
  }, []);

  useEffect(refresh, [refresh]);

  if (error) {
    return (
      <div className="centered-auth">
        <div className="card">
          <p className="error-banner">{error}</p>
        </div>
      </div>
    );
  }

  if (!status) {
    return (
      <div className="centered-auth">
        <p className="subtitle">Loading…</p>
      </div>
    );
  }

  if (status.setup_required) {
    return <SetupPassword onDone={refresh} />;
  }

  if (!status.authenticated) {
    return <Login onDone={refresh} />;
  }

  return (
    <Dashboard
      onLogout={async () => {
        await api.logout();
        refresh();
      }}
    />
  );
}
