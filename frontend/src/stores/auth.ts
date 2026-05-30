import { ref, computed } from 'vue'
import { defineStore } from 'pinia'
import { login as apiLogin, register as apiRegister, changePassword as apiChangePassword } from '@/api/auth'

export interface User {
  id: string
  name: string
  role: 'student' | 'teacher' | 'admin'
  major?: string
  needs_password_change?: boolean
}

function isTokenExpired(token: string): boolean {
  try {
    const parts = token.split('.')
    if (parts.length < 2) return true
    const payload = JSON.parse(atob(parts[1]!))
    if (!payload.exp) return false
    // exp 是秒级时间戳，提前 10 秒判定过期避免临界请求失败
    return payload.exp * 1000 < Date.now() + 10_000
  } catch {
    return true
  }
}

export const useAuthStore = defineStore('auth', () => {
  const storedUser = localStorage.getItem('auth_user')
  const storedToken = localStorage.getItem('auth_token')

  // 启动时检查 token 是否过期，过期则清除
  if (storedToken && isTokenExpired(storedToken)) {
    localStorage.removeItem('auth_user')
    localStorage.removeItem('auth_token')
  }

  const user = ref<User | null>(
    localStorage.getItem('auth_token') ? (storedUser ? JSON.parse(storedUser) : null) : null,
  )
  const token = ref<string | null>(localStorage.getItem('auth_token'))

  const isLoggedIn = computed(() => !!user.value)

  async function login(id: string, password: string): Promise<boolean> {
    try {
      const result = await apiLogin({ id, password })
      const u: User = {
        id: result.user.id,
        name: result.user.name,
        role: result.user.role as 'student' | 'teacher' | 'admin',
        major: result.user.major,
        needs_password_change: result.user.needs_password_change,
      }
      user.value = u
      token.value = result.access_token
      localStorage.setItem('auth_user', JSON.stringify(u))
      localStorage.setItem('auth_token', result.access_token)
      return true
    } catch {
      return false
    }
  }

  async function register(id: string, name: string, password: string, role: 'student' | 'teacher', major?: string): Promise<boolean> {
    try {
      await apiRegister({ id, name, password, role, major })
      // 注册成功后自动登录
      return await login(id, password)
    } catch {
      return false
    }
  }

  function logout() {
    user.value = null
    token.value = null
    localStorage.removeItem('auth_user')
    localStorage.removeItem('auth_token')
  }

  async function changePassword(oldPassword: string, newPassword: string): Promise<boolean> {
    try {
      await apiChangePassword({ old_password: oldPassword, new_password: newPassword })
      // 修改密码成功后，清除强制改密标记
      if (user.value) {
        user.value.needs_password_change = false
        localStorage.setItem('auth_user', JSON.stringify(user.value))
      }
      return true
    } catch {
      return false
    }
  }

  return { user, token, isLoggedIn, login, register, logout, changePassword }
})
