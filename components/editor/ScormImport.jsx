'use client'

// Choix du fichier SCORM et avancement de l'envoi.
export default function ScormImport({ onFile, progress }) {
  return (
    <>
      <label>Fichier SCORM (.zip)<input key="scorm" type="file" accept=".zip,application/zip" onChange={e => onFile(e.target.files?.[0] || null)} /></label>
      <p className="muted small">SCORM 1.2, un seul module par paquet. 150 Mo au maximum, 50 Mo par fichier. Gardez cette page ouverte pendant l’envoi.</p>
      {progress && (
        <div role="status">
          <progress max={progress.total} value={progress.done} aria-label="Envoi du module" /> {progress.done} / {progress.total} fichiers
        </div>
      )}
    </>
  )
}
