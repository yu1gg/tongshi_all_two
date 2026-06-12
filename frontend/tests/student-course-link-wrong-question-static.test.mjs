import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')

function read(relativePath) {
  return readFileSync(resolve(root, relativePath), 'utf8')
}

const courseApi = read('src/api/course.ts')
const learn = read('src/views/LearnView.vue')
const practice = read('src/views/PracticeView.vue')
const upload = read('src/views/ProjectUploadView.vue')
const detail = read('src/views/ProjectDetailView.vue')
const profileApi = read('src/api/profile.ts')
const profile = read('src/views/ProfileView.vue')

assert.match(courseApi, /getCourseList/, 'course API should expose a result that preserves hint.')
assert.match(learn, /getCourseList/, 'LearnView should keep course hint instead of discarding it.')
assert.match(learn, /courseHint/, 'LearnView should render backend course empty-state hint.')
assert.match(practice, /getCourseList/, 'PracticeView should use the same student course response.')
assert.doesNotMatch(practice, /filter\(c\s*=>\s*!c\.is_public\)/, 'PracticeView must not infer enrollment from is_public.')
assert.match(upload, /getCourseList/, 'ProjectUploadView should load enrolled course options with hint support.')
assert.match(upload, /form\.linkUrl\s*=\s*project\.link_url\s*\|\|\s*project\.video_url\s*\|\|\s*''/, 'ProjectUploadView should migrate old video link into the single link field.')
assert.doesNotMatch(upload, /v-model="form\.videoUrl"/, 'ProjectUploadView should not render a separate video link input.')
assert.doesNotMatch(upload, /演示视频链接/, 'ProjectUploadView should not keep the old video link label.')
assert.match(upload, /作品链接/, 'ProjectUploadView should render one project link field.')
assert.match(detail, /projectLink/, 'ProjectDetailView should render a single computed project link.')
assert.doesNotMatch(detail, /project\.video_url" class="detail-section"[\s\S]*project\.link_url" class="detail-section"/, 'ProjectDetailView should not render two separate link sections.')
assert.match(profileApi, /course_name:\s*string/, 'WrongQuestion type should include course_name.')
assert.match(profileApi, /type:\s*string/, 'WrongQuestion type should include question type.')
assert.match(profile, /wrongQuestionGroups/, 'ProfileView should group wrong questions by course.')
assert.match(profile, /course\.questions/, 'ProfileView should render questions inside each course group.')
assert.match(profile, /isOptionCorrect/, 'ProfileView should use helper logic for option correctness.')
