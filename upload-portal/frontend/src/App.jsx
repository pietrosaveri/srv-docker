import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import AdminApp from "./admin/AdminApp.jsx";
import UploadPage from "./client/UploadPage.jsx";

function Landing() {
  return (
    <div className="client-page">
      <div className="client-card">
        <h1>Upload Portal</h1>
        <p className="subtitle">This is a private file-upload service.</p>
      </div>
    </div>
  );
}

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Landing />} />
        <Route path="/admin/*" element={<AdminApp />} />
        <Route path="/u/:token" element={<UploadPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </BrowserRouter>
  );
}
