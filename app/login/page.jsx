'use client'

import { useState } from 'react'
import { createClient } from '../../lib/supabase-browser'

export default function Login() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  async function submit(event) {
    event.preventDefault()
    setError('')
    setLoading(true)

    try {
      const { error: authError } = await createClient().auth.signInWithPassword({
        email: email.trim(),
        password,
      })

      if (authError) {
        setError(
          authError.status === 400
            ? 'Adresse e-mail ou mot de passe incorrect. Si c’est votre première connexion, votre compte doit d’abord recevoir un mot de passe.'
            : 'La connexion est momentanément impossible. Réessayez dans quelques instants.'
        )
        return
      }

      window.location.assign('/')
    } catch {
      setError('Impossible de joindre le service de connexion. Vérifiez votre connexion puis réessayez.')
    } finally {
      setLoading(false)
    }
  }

  return (
    <main className="shell">
      <section className="card login">
        <div className="eyebrow">LMS IFAP</div>
        <h1>Connexion</h1>
        <p>Accédez à votre espace de formation avec votre adresse e-mail et votre mot de passe.</p>

        <form onSubmit={submit}>
          <label>
            E-mail professionnel
            <input
              type="email"
              required
              autoComplete="username"
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              placeholder="vous@collectivite.nc"
            />
          </label>

          <label>
            Mot de passe
            <input
              type="password"
              required
              autoComplete="current-password"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              placeholder="Votre mot de passe"
            />
          </label>

          {error && <div className="error" role="alert">{error}</div>}

          <button type="submit" disabled={loading}>
            {loading ? 'Connexion en cours…' : 'Se connecter'}
          </button>
        </form>

        <p className="muted small" style={{ marginTop: 18 }}>
          Vous n’avez pas encore de mot de passe ou vous l’avez oublié ? Contactez l’administrateur de votre organisation.
        </p>
      </section>
    </main>
  )
}
