# 学生端课程入口、作品链接和错题分组 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 学生端所有课程入口只显示学生已加入班级对应的课程，作品提交页只保留一个作品链接入口，个人中心错题本按课程折叠分组。

**Architecture:** 后端把学生课程列表口径收敛到“已加入班级课程”，并在返回对象中保留空状态提示；前端学习、练习、作品上传页复用同一课程列表口径，不再用 `is_public` 判断是否已加入。错题接口补充课程名和题型，前端在个人中心按课程做一层分组折叠，课程内继续展示题目明细。

**Tech Stack:** FastAPI + SQLAlchemy + Pydantic；Vue 3 `<script setup lang="ts">` + Element Plus；后端测试使用 pytest，前端使用静态 Node 检查和 Vite build。

---

## 范围

本计划处理：
- 学生端 `/learn`、`/practice`、`/create/upload` 的课程列表只来自学生已加入班级对应课程。
- 学生没有加入课程时，学习页、练习页、作品提交页显示可理解空状态。
- 作品提交页合并 `videoUrl` 和 `linkUrl` 两个输入，只保留“作品链接”。
- 作品详情页把视频链接和外链合并为一个展示区，兼容历史 `video_url` 数据。
- 错题本接口返回 `course_name` 和 `type`，个人中心按课程折叠展示错题。

本计划不处理：
- 教师端公共课程导入、复制和同步机制。
- 错题本“历史错题”与“当前仍未掌握”的业务口径变化。
- 新增数据库迁移框架。
- 已有“作品课程归属与教师审核权限”改动的回滚或重写。

## 涉及文件

- Modify: `backend/app/services/course_response_service.py`
  - 学生课程列表只取已加入课程，并返回空状态提示。
- Modify: `backend/app/api/v1/routes/course_routes.py`
  - 学生课程列表保留 `{ courses, hint }` 响应，避免前端丢失提示。
- Modify: `frontend/src/api/course.ts`
  - 增加 `getCourseList()`，保留 `hint`；旧 `getCourses()` 兼容返回课程数组。
- Modify: `frontend/src/views/LearnView.vue`
  - 使用带 `hint` 的课程列表响应，空状态显示后端提示。
- Modify: `frontend/src/views/PracticeView.vue`
  - 使用同一课程列表，不再按 `!is_public` 过滤。
- Modify: `frontend/src/views/ProjectUploadView.vue`
  - 课程选择使用学生已加入课程；合并作品链接输入，提交时只写 `link_url`，编辑时兼容旧 `video_url`。
- Modify: `frontend/src/views/ProjectDetailView.vue`
  - 合并作品链接展示，优先 `link_url`，兜底 `video_url`。
- Modify: `backend/app/services/quiz_service.py`
  - 错题项补充 `type`、`course_name`，并限制在学生已加入课程范围内。
- Modify: `frontend/src/api/profile.ts`
  - `WrongQuestion` 类型补充 `type`、`course_name`。
- Modify: `frontend/src/views/ProfileView.vue`
  - 错题按课程分组折叠，课程内题目继续折叠展示。
- Create: `backend/tests/test_student_course_visibility.py`
  - 覆盖学生课程列表不包含未加入公共课程、无班级提示、错题课程信息。
- Create: `frontend/tests/student-course-link-wrong-question-static.test.mjs`
  - 静态检查前端已使用新课程响应、作品单链接和错题分组。

## 任务

### Task 1: 写失败测试

- [ ] 新增 `backend/tests/test_student_course_visibility.py`，覆盖学生课程列表只返回已加入课程、无班级学生拿到提示、错题项返回课程名和题型。
- [ ] 新增 `frontend/tests/student-course-link-wrong-question-static.test.mjs`，检查 `LearnView`、`PracticeView`、`ProjectUploadView`、`ProjectDetailView`、`ProfileView` 的关键结构。
- [ ] 运行：

```powershell
py -m pytest backend\tests\test_student_course_visibility.py -q
node frontend\tests\student-course-link-wrong-question-static.test.mjs
```

预期：测试失败，原因分别是当前学生课程列表包含公共课、错题项缺课程名/题型，前端尚未合并作品链接和错题分组。

### Task 2: 统一学生课程列表口径

- [ ] 修改 `course_response_service.build_course_list`：学生只查询 `enrolled_course_ids`，不再拼入 `Course.is_public == True`。
- [ ] 学生没有任何班级时返回 `hint: "你尚未加入任何班级，请联系老师"`；有班级但没有课程时返回 `hint: "你所在班级尚未关联课程，请联系老师"`。
- [ ] 修改 `course_routes.get_courses`：学生端始终返回 `{ courses, hint }`，不再把 dict 压平成数组。
- [ ] 修改 `frontend/src/api/course.ts`：新增 `getCourseList()` 返回 `CourseListResult`，`getCourses()` 调用它并返回 `courses` 以兼容教师端旧代码。

### Task 3: 学习页、练习页和作品上传页复用课程口径

- [ ] `LearnView.vue` 调用 `getCourseList()`，记录 `courseHint`，空列表时优先显示提示。
- [ ] `PracticeView.vue` 调用 `getCourseList()`，删除 `enrolledCourses = courses.filter(c => !c.is_public)`，所有课程卡直接来自后端已加入课程列表。
- [ ] `ProjectUploadView.vue` 调用 `getCourseList()`，课程为空时显示“暂无可提交作品的课程，请先加入老师创建的课程班级”。

### Task 4: 合并作品链接

- [ ] `ProjectUploadView.vue` 删除“演示视频链接”输入，只保留“作品链接”输入。
- [ ] 编辑旧作品时 `form.linkUrl = project.link_url || project.video_url || ''`。
- [ ] 提交 payload 时 `link_url` 使用表单值，`video_url` 不再写入新值。
- [ ] `ProjectDetailView.vue` 新增 `projectLink` 计算属性，优先 `project.link_url`，兜底 `project.video_url`；模板只显示一个“作品链接”区块。

### Task 5: 错题按课程折叠分组

- [ ] `quiz_service.get_wrong_questions` 对错题加入 `Question.course_id -> Course.name` 映射，并返回 `type`、`course_name`。
- [ ] 查询错题时限制在学生已加入课程范围内，避免已脱离课程或越权课程错题继续显示。
- [ ] `profile.ts` 补充 `WrongQuestion.type`、`course_name`。
- [ ] `ProfileView.vue` 新增 `wrongQuestionGroups` 计算属性，按 `course_id` 分组；模板第一层折叠课程，第二层折叠题目。
- [ ] 多选题选项高亮改为集合判断，避免只适配单选题。

### Task 6: 验证和同步

- [ ] 运行后端目标测试：

```powershell
py -m pytest backend\tests\test_student_course_visibility.py backend\tests\test_project_course_scope.py backend\tests\test_schema_compat.py -q
```

- [ ] 运行前端静态测试：

```powershell
node frontend\tests\student-course-link-wrong-question-static.test.mjs
node frontend\tests\project-upload-course-static.test.mjs
```

- [ ] 在 `frontend` 目录运行：

```powershell
npm run build
```

- [ ] 运行：

```powershell
git diff --check
graphify update .
```

验收标准：
- `/learn` 不再显示学生未加入的公共课程。
- `/practice` 显示学生已加入课程，不再因为 `is_public` 被误过滤。
- `/create/upload` 的课程选择只来自学生已加入课程。
- `/create/upload` 只显示一个作品链接输入。
- `/create/project/:id` 只显示一个作品链接区块，并兼容旧视频链接。
- 个人中心错题本第一层按课程折叠，课程内展示错题。
- 新增测试和构建通过；如本地环境限制导致无法验证，需要在总结中说明。
