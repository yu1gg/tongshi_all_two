import assert from 'node:assert/strict'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const counterPath = resolve(root, 'src/stores/counter.ts')

function collectFiles(dir) {
  const result = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = resolve(dir, entry.name)
    if (entry.isDirectory()) {
      result.push(...collectFiles(full))
    } else if (/\.(ts|vue|mjs)$/.test(entry.name)) {
      result.push(full)
    }
  }
  return result
}

assert.equal(existsSync(counterPath), false, 'counter.ts 示例 store 应删除')

for (const file of collectFiles(resolve(root, 'src'))) {
  const content = readFileSync(file, 'utf8')
  assert.doesNotMatch(content, /stores\/counter|useCounterStore/, `${file} 不应引用 counter store`)
}
