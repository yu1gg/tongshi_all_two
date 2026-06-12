import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')

function read(relativePath) {
  return readFileSync(resolve(root, relativePath), 'utf8')
}

const upload = read('src/views/ProjectUploadView.vue')
const projectApi = read('src/api/project.ts')

assert.match(upload, /getCourseList/, 'ProjectUploadView should load student course options with hint support.')
assert.match(upload, /form\.courseId/, 'ProjectUploadView should keep selected course id in form state.')
assert.match(upload, /请选择关联课程/, 'ProjectUploadView should validate course selection before submit.')
assert.match(upload, /course_id:\s*selectedCourseId/, 'Project payload should include course_id.')
assert.match(upload, /关联课程/, 'ProjectUploadView should render a course selection field.')
assert.match(upload, /作品链接/, 'ProjectUploadView should render one project link field.')
assert.doesNotMatch(upload, /v-model="form\.videoUrl"/, 'ProjectUploadView should not render a separate video link field.')
assert.match(projectApi, /course_id:\s*number/, 'ProjectPayload should require course_id.')
