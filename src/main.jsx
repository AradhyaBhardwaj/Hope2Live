import React, { Suspense } from "react";
import ReactDOM from "react-dom/client";
import "./App.css";

const App = React.lazy(() => import("./App"));

ReactDOM.createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <Suspense
      fallback={
        <main className="app-loading-screen" aria-busy="true">
          Loading Hope2Live...
        </main>
      }
    >
      <App />
    </Suspense>
  </React.StrictMode>
);