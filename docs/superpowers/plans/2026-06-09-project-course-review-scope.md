# 作品课程归属与教师审核权限 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 学生提交作品时必须选择自己已加入的课程，教师只能查看和审核自己课程范围内的作品。

**Architecture:** 给 `projects` 增加可兼容旧数据的 `course_id` 字段；学生提交和重新提交时由后端校验课程归属；教师端作品列表和审核写操作统一通过教师课程范围过滤。旧作品 `course_id` 为空时，仅在作者属于教师班级的情况下保留教师端可见性，避免历史作品突然不可审核。

**Tech Stack:** FastAPI + SQLAlchemy + Pydantic；Vue 3 `<script setup lang="ts">` + Element Plus；后端测试使用 pytest + SQLite 内存库，前端使用 `vue-tsc`/Vite build 与静态检查。

---

## 范围

本计划只处理以下事项：

- 学生端提交作品和驳回后重新提交时选择关联课程。
- 后端保存作品时校验学生已加入该课程对应班级。
- 教师端作品列表、通过、驳回、删除接口按教师课程范围收口。
- 清理已经删除的 `StudentProgress` 在测试和项目地图中的陈旧引用。

本计划不处理以下事项：

- 消息接口容错拆分。
- 未开始作业在学生列表入口的前端禁用。
- 作品广场展示策略改版。
- 新增复杂迁移框架或 Alembic 迁移脚本。

## 文件结构

- 修改：`backend/app/models/entities.py`
  - `Project` 新增 `course_id` 外键和 `course` relationship。
- 修改：`backend/app/db/schema_compat.py`
  - 旧库自动补齐 `projects.course_id`。
- 修改：`backend/app/schemas/common.py`
  - `ProjectCreate`、`ProjectUpdate`、`ProjectOut` 增加课程字段。
- 修改：`backend/app/services/project_service.py`
  - 保存作品时校验学生课程归属；格式化响应返回课程信息；教师审核写操作支持教师范围校验。
- 修改：`backend/app/services/teacher_service.py`
  - 作品列表按教师课程范围过滤，并保留旧作品作者班级兜底。
- 修改：`backend/app/api/v1/routes/teacher_routes.py`
  - approve/reject/delete 传入当前教师 ID。
- 修改：`frontend/src/api/project.ts`
  - Project 类型和提交 payload 增加 `course_id`、`course_name`。
- 修改：`frontend/src/views/ProjectUploadView.vue`
  - 拉取学生课程，新增必填课程选择，提交 payload 带 `course_id`。
- 新增：`frontend/tests/project-upload-course-static.test.mjs`
  - 静态检查提交页必须有课程选择、必填校验和 payload 字段。
- 修改：`backend/tests/test_schema_compat.py`
  - 覆盖旧库补齐 `projects.course_id`。
- 新增：`backend/tests/test_project_course_scope.py`
  - 覆盖学生提交课程校验和教师审核权限边界。
- 修改：`backend/tests/test_integration_bugfixes.py`
  - 删除 `StudentProgress` 导入和已失效测试；给现有作品创建请求补充 `course_id`。
- 修改：`docs/superpowers/project-map.md`
  - 删除 `StudentProgress` 作为稳定架构事实；补充作品挂课程和教师审核范围。

---

### Task 1: 后端测试先行：作品课程归属和教师审核权限

**Files:**
- Create: `backend/tests/test_project_course_scope.py`
- Modify: `backend/tests/test_schema_compat.py`

- [ ] **Step 1: 新增失败测试文件**

创建 `backend/tests/test_project_course_scope.py`，内容如下：

```python
"""作品课程归属和教师审核权限回归测试。"""

from app.core.security import get_password_hash
from app.models.entities import Class, Course, Project, StudentClassEnrollment, User
from tests.conftest import auth_header


def _login(client, user_id: str, password: str = "abc123") -> str:
    return client.post("/api/token", json={"id": user_id, "password": password}).json()["data"]["access_token"]


def _create_project(client, token: str, course_id: int, title: str = "课程作品") -> int:
    resp = client.post(
        "/api/projects",
        json={
            "course_id": course_id,
            "title": title,
            "description": "作品说明",
            "tags": ["AI"],
            "image_urls": [],
            "image_file_ids": [],
        },
        headers=auth_header(token),
    ).json()
    assert resp["code"] == 0
    return resp["data"]["id"]


def test_student_must_submit_project_to_enrolled_course(client, db_session, student_token):
    other_course = db_session.query(Course).filter(Course.created_by == "T002").first()

    resp = client.post(
        "/api/projects",
        json={
            "course_id": other_course.id,
            "title": "越权课程作品",
            "description": "作品说明",
            "tags": [],
        },
        headers=auth_header(student_token),
    ).json()

    assert resp["code"] == 403
    assert "只能选择自己已加入的课程" in resp["message"]


def test_project_create_persists_course_and_returns_course_name(client, db_session, student_token):
    course = db_session.query(Course).filter(Course.created_by == "T001").first()
    project_id = _create_project(client, student_token, course.id)

    detail = client.get(f"/api/projects/{project_id}", headers=auth_header(student_token)).json()

    assert detail["code"] == 0
    assert detail["data"]["course_id"] == course.id
    assert detail["data"]["course_name"] == course.name


def test_project_resubmit_can_set_course_for_legacy_rejected_project(client, db_session, student_token):
    course = db_session.query(Course).filter(Course.created_by == "T001").first()
    legacy = Project(
        title="旧作品",
        author_id="2025001",
        description="旧作品说明",
        status="rejected",
        reject_reason="补充课程",
    )
    db_session.add(legacy)
    db_session.commit()

    resp = client.put(
        f"/api/projects/{legacy.id}",
        json={
            "course_id": course.id,
            "title": "旧作品重新提交",
            "description": "补充课程后重新提交",
            "tags": [],
            "image_urls": [],
            "image_file_ids": [],
        },
        headers=auth_header(student_token),
    ).json()
    db_session.refresh(legacy)

    assert resp["code"] == 0
    assert legacy.status == "pending"
    assert legacy.course_id == course.id


def test_teacher_only_lists_projects_in_own_course_scope(client, db_session, student_token, teacher_token):
    own_course = db_session.query(Course).filter(Course.created_by == "T001").first()
    own_project_id = _create_project(client, student_token, own_course.id, "本教师课程作品")

    other_student = User(
        id="2025999",
        name="其他教师学生",
        hashed_password=get_password_hash("abc123"),
        role="student",
        major="人工智能",
    )
    db_session.add(other_student)
    other_course = db_session.query(Course).filter(Course.created_by == "T002").first()
    other_class = db_session.query(Class).filter(Class.course_id == other_course.id).first()
    db_session.add(StudentClassEnrollment(user_id=other_student.id, class_id=other_class.id))
    db_session.add(Project(title="其他教师课程作品", author_id=other_student.id, course_id=other_course.id, status="pending"))
    db_session.commit()

    resp = client.get("/api/teacher/projects", headers=auth_header(teacher_token)).json()
    ids = [item["id"] for item in resp["data"]["items"]]

    assert resp["code"] == 0
    assert own_project_id in ids
    assert len(ids) == 1


def test_other_teacher_cannot_approve_reject_or_delete_project_outside_scope(client, db_session, student_token):
    course = db_session.query(Course).filter(Course.created_by == "T001").first()
    project_id = _create_project(client, student_token, course.id, "不可越权审核")
    other_teacher_token = _login(client, "T002")

    approve = client.post(
        f"/api/teacher/projects/{project_id}/approve",
        headers=auth_header(other_teacher_token),
    ).json()
    reject = client.post(
        f"/api/teacher/projects/{project_id}/reject",
        json={"reason": "越权驳回"},
        headers=auth_header(other_teacher_token),
    ).json()
    delete = client.delete(
        f"/api/teacher/projects/{project_id}",
        headers=auth_header(other_teacher_token),
    ).json()
    project = db_session.query(Project).filter(Project.id == project_id).one()

    assert approve["code"] == 404
    assert reject["code"] == 404
    assert delete["code"] == 404
    assert project.status == "pending"


def test_owner_teacher_can_approve_project_in_course_scope(client, db_session, student_token, teacher_token):
    course = db_session.query(Course).filter(Course.created_by == "T001").first()
    project_id = _create_project(client, student_token, course.id, "可审核作品")

    resp = client.post(
        f"/api/teacher/projects/{project_id}/approve",
        headers=auth_header(teacher_token),
    ).json()
    project = db_session.query(Project).filter(Project.id == project_id).one()

    assert resp["code"] == 0
    assert project.status == "approved"
```

- [ ] **Step 2: 给兼容脚本增加失败测试**

在 `backend/tests/test_schema_compat.py` 末尾追加：

```python
def test_ensure_schema_compatibility_adds_project_course_id():
    """旧库 projects 表应自动补齐 course_id 列。"""
    engine = create_engine("sqlite:///:memory:")
    with engine.begin() as conn:
        conn.execute(text("""
            CREATE TABLE projects (
                id INTEGER PRIMARY KEY,
                title VARCHAR(128) NOT NULL,
                author_id VARCHAR(32) NOT NULL
            )
        """))

    ensure_schema_compatibility(engine)

    inspector = inspect(engine)
    columns = {column["name"] for column in inspector.get_columns("projects")}

    assert "course_id" in columns
```

- [ ] **Step 3: 运行测试确认失败**

Run:

```powershell
py -m pytest backend\tests\test_project_course_scope.py backend\tests\test_schema_compat.py -q
```

Expected:

- `test_project_course_scope.py` 中多个用例失败，原因包括 `ProjectCreate` 不接受/不保存 `course_id`，教师越权审核仍返回成功。
- `test_ensure_schema_compatibility_adds_project_course_id` 失败，原因是旧库未补齐 `projects.course_id`。

---

### Task 2: 数据模型、Schema 和旧库兼容

**Files:**
- Modify: `backend/app/models/entities.py`
- Modify: `backend/app/db/schema_compat.py`
- Modify: `backend/app/schemas/common.py`

- [ ] **Step 1: 修改 ORM 模型**

在 `backend/app/models/entities.py` 的 `Project` 中加入 `course_id` 和 relationship。目标片段：

```python
class Project(Base):
    __tablename__ = "projects"
    id = Column(Integer, primary_key=True, autoincrement=True)
    title = Column(String(128), nullable=False)
    author_id = Column(String(32), ForeignKey(
        "users.id"), nullable=False, index=True)
    course_id = Column(Integer, ForeignKey(
        "courses.id"), nullable=True, index=True)
    major = Column(String(64), default="")
    description = Column(Text, default="")
    tags = Column(JSON, default=list)
    likes = Column(Integer, default=0)
    featured = Column(Boolean, default=False)
    video_url = Column(String(512), default="")
    report_url = Column(String(512), default="")
    image_url = Column(String(512), default="")
    link_url = Column(String(512), default="")
    status = Column(String(16), default="pending")
    reject_reason = Column(String(256), default="")
    date = Column(String(32), default="")
    report_file_id = Column(Integer, ForeignKey(
        "stored_files.id"), nullable=True, index=True)
    cover_file_id = Column(Integer, ForeignKey(
        "stored_files.id"), nullable=True, index=True)

    author = relationship("User", back_populates="projects")
    course = relationship("Course")
```

`course_id` 必须是 `nullable=True`，用于兼容旧作品。

- [ ] **Step 2: 修改兼容脚本**

在 `backend/app/db/schema_compat.py` 已有 projects 列补齐附近加入：

```python
        _add_column_if_missing(conn, inspector, "projects",
                               "course_id", "INTEGER")
```

位置建议放在 `report_file_id` 和 `cover_file_id` 前后，保持 projects 字段集中。

- [ ] **Step 3: 修改 Pydantic Schema**

在 `backend/app/schemas/common.py` 修改 `ProjectOut`、`ProjectCreate`、`ProjectUpdate`：

```python
class ProjectOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    title: str
    author_id: str
    author_name: str = ""
    course_id: Optional[int] = None
    course_name: str = ""
    major: str = ""
```

```python
class ProjectCreate(BaseModel):
    course_id: int
    title: str = Field(min_length=1)
    description: str = ""
    tags: List[str] = []
```

```python
class ProjectUpdate(BaseModel):
    course_id: int
    title: str = Field(min_length=1)
    description: str = ""
    tags: List[str] = []
```

- [ ] **Step 4: 运行兼容测试确认通过**

Run:

```powershell
py -m pytest backend\tests\test_schema_compat.py -q
```

Expected: `test_ensure_schema_compatibility_adds_project_course_id` 通过，其他兼容测试保持通过。

---

### Task 3: 后端服务层实现学生课程校验和教师审核范围

**Files:**
- Modify: `backend/app/services/project_service.py`
- Modify: `backend/app/services/teacher_service.py`
- Modify: `backend/app/api/v1/routes/teacher_routes.py`

- [ ] **Step 1: 在 project_service 增加课程权限辅助函数**

在 `backend/app/services/project_service.py` imports 中加入 `Class`、`Course`、`StudentClassEnrollment`：

```python
from app.models.entities import Class, Course, Project, ProjectImage, ProjectLike, StudentClassEnrollment, User
```

在 `normalize_project_images` 前增加：

```python
def _student_can_submit_to_course(db: Session, user_id: str, course_id: int) -> bool:
    """学生只能将作品提交到自己已加入班级对应的课程。"""
    return db.query(StudentClassEnrollment).join(
        Class, Class.id == StudentClassEnrollment.class_id,
    ).filter(
        StudentClassEnrollment.user_id == user_id,
        Class.course_id == course_id,
    ).first() is not None


def _teacher_can_review_project(db: Session, project: Project, teacher_id: str) -> bool:
    """教师只能审核自己课程下的作品；旧作品无 course_id 时按作者班级兜底。"""
    if project.course_id is not None:
        return db.query(Course).filter(
            Course.id == project.course_id,
            Course.created_by == teacher_id,
        ).first() is not None

    return db.query(StudentClassEnrollment).join(
        Class, Class.id == StudentClassEnrollment.class_id,
    ).join(
        Course, Course.id == Class.course_id,
    ).filter(
        StudentClassEnrollment.user_id == project.author_id,
        Course.created_by == teacher_id,
    ).first() is not None


def get_reviewable_project(db: Session, project_id: int, teacher_id: str) -> Project | None:
    """获取当前教师可审核的作品。"""
    project = get_project(db, project_id)
    if not project:
        return None
    if not _teacher_can_review_project(db, project, teacher_id):
        return None
    return project
```

- [ ] **Step 2: 修改 create_project**

在 `create_project` 中读取并校验 `course_id`：

```python
def create_project(db: Session, user_id: str, data: dict):
    course_id = data.get("course_id")
    if not course_id or not _student_can_submit_to_course(db, user_id, course_id):
        raise BusinessException(403, "只能选择自己已加入的课程提交作品")

    user = db.query(User).filter(User.id == user_id).first()
    project = Project(
        author_id=user_id,
        course_id=course_id,
        major=user.major if user else "",
        date=datetime.now().strftime("%Y-%m-%d"),
        title=data.get("title"),
```

保留函数后续图片同步、commit、日志逻辑不变。

- [ ] **Step 3: 修改 update_project**

在 `update_project` 中校验课程并写入：

```python
    course_id = data.get("course_id")
    if not course_id or not _student_can_submit_to_course(db, user_id, course_id):
        raise BusinessException(403, "只能选择自己已加入的课程提交作品")

    project.title = data.get("title", project.title)
    project.course_id = course_id
    project.description = data.get("description", "")
```

其余状态重置、文件字段、图片同步逻辑保持不变。

- [ ] **Step 4: 修改审核写操作服务签名**

把 `approve_project`、`reject_project`、`delete_project` 改为接收 `teacher_id`：

```python
def approve_project(db: Session, project_id: int, teacher_id: str | None = None):
    project = get_project(db, project_id)
    if not project:
        return None
    if teacher_id is not None and not _teacher_can_review_project(db, project, teacher_id):
        return None
    project.status = "approved"
```

```python
def reject_project(db: Session, project_id: int, reason: str, teacher_id: str | None = None):
    project = get_project(db, project_id)
    if not project:
        return None
    if teacher_id is not None and not _teacher_can_review_project(db, project, teacher_id):
        return None
    project.status = "rejected"
```

```python
def delete_project(db: Session, project_id: int, teacher_id: str | None = None):
    """删除作品及其关联数据。"""
    project = get_project(db, project_id)
    if not project:
        return None
    if teacher_id is not None and not _teacher_can_review_project(db, project, teacher_id):
        return None
```

保留 `teacher_id=None` 是为了不影响其他内部调用；教师路由必须传入当前教师 ID。

- [ ] **Step 5: 修改 format_project 返回课程字段**

在 `format_project` 中加入课程名查询：

```python
    course_name = p.course.name if getattr(p, "course", None) else ""
```

返回 dict 中加入：

```python
        "course_id": getattr(p, "course_id", None),
        "course_name": course_name,
```

位置放在 `author_name` 后，便于前端展示。

- [ ] **Step 6: 修改 teacher_service 作品列表过滤**

在 `backend/app/services/teacher_service.py` imports 增加 `or_`：

```python
from sqlalchemy import or_
```

修改 `list_all_projects` 中 `teacher_id` 分支：

```python
    if teacher_id:
        student_ids = _teacher_student_ids(db, teacher_id)
        course_ids = [
            row.id for row in db.query(Course.id)
            .filter(Course.created_by == teacher_id)
            .all()
        ]
        filters = []
        if course_ids:
            filters.append(Project.course_id.in_(course_ids))
        if student_ids:
            filters.append(Project.course_id.is_(None) & Project.author_id.in_(student_ids))
        if filters:
            query = query.filter(or_(*filters))
        else:
            query = query.filter(False)
```

这样新作品按 `course_id`，旧作品按作者是否属于教师班级兜底。

- [ ] **Step 7: 修改教师路由传入 current_user.id**

在 `backend/app/api/v1/routes/teacher_routes.py` 中修改三个写接口：

```python
@router.post("/projects/{project_id}/approve", summary="通过作品审核", description="教师端：将指定作品设为审核通过")
def approve(project_id: int, db: Session = Depends(get_db), current_user: AuthUser = Depends(require_role("teacher"))):
    p = approve_project(db, project_id, current_user.id)
    if not p:
        raise BusinessException(404, "作品不存在")
    return success()
```

```python
    p = reject_project(db, project_id, data.reason or "", current_user.id)
```

```python
    p = delete_project(db, project_id, current_user.id)
```

- [ ] **Step 8: 运行后端范围测试**

Run:

```powershell
py -m pytest backend\tests\test_project_course_scope.py backend\tests\test_schema_compat.py -q
```

Expected: 新增课程归属和教师越权测试通过。

---

### Task 4: 学生提交页新增课程选择

**Files:**
- Modify: `frontend/src/api/project.ts`
- Modify: `frontend/src/views/ProjectUploadView.vue`
- Create: `frontend/tests/project-upload-course-static.test.mjs`

- [ ] **Step 1: 更新前端 Project 类型和 payload**

在 `frontend/src/api/project.ts` 中修改：

```ts
export interface Project {
  id: number
  title: string
  author_id: string
  author_name: string
  course_id?: number | null
  course_name?: string
  major: string
```

```ts
export interface ProjectPayload {
  course_id: number
  title: string
  description: string
  tags: string[]
```

- [ ] **Step 2: ProjectUploadView 引入课程 API**

修改 import：

```ts
import { getCourses, type Course } from '@/api/course'
```

表单状态增加：

```ts
const form = reactive({
  courseId: null as number | null,
  title: '',
  description: '',
  videoUrl: '',
  linkUrl: '',
})
```

新增课程列表状态：

```ts
const courses = ref<Course[]>([])
const courseLoading = ref(false)
```

- [ ] **Step 3: 加载学生可选课程**

在 `loadProjectForEdit` 前增加：

```ts
async function loadCourses() {
  courseLoading.value = true
  try {
    courses.value = (await getCourses()).filter(course => !course.is_public)
  } catch {
    ElMessage.error('课程列表加载失败，请稍后重试')
  } finally {
    courseLoading.value = false
  }
}
```

修改编辑回填：

```ts
    form.courseId = project.course_id ?? null
```

修改 `onMounted`：

```ts
onMounted(async () => {
  await loadCourses()
  await loadProjectForEdit()
})
```

- [ ] **Step 4: 提交时校验课程并带入 payload**

在 `handleSubmit` 标题校验前加入：

```ts
  if (!form.courseId) {
    ElMessage.warning('请选择关联课程')
    return
  }
  const selectedCourseId = form.courseId
```

payload 增加：

```ts
    const payload: ProjectPayload = {
      course_id: selectedCourseId,
      title: form.title.trim(),
```

- [ ] **Step 5: 页面模板增加课程选择**

在提交人/专业信息之后、作品名称之前加入：

```vue
        <div class="form-group">
          <label>关联课程 <span class="req">*</span></label>
          <el-select
            v-model="form.courseId"
            placeholder="请选择作品对应的课程"
            size="large"
            style="width: 100%"
            :loading="courseLoading"
          >
            <el-option
              v-for="course in courses"
              :key="course.id"
              :label="course.name"
              :value="course.id"
            />
          </el-select>
          <p v-if="!courseLoading && courses.length === 0" class="form-hint">
            暂无可提交作品的课程，请先加入老师创建的课程班级。
          </p>
        </div>
```

在 `<style scoped>` 中增加：

```css
.form-hint {
  margin-top: var(--space-xs);
  font-size: 0.78rem;
  color: var(--color-text-muted);
}
```

- [ ] **Step 6: 新增前端静态测试**

创建 `frontend/tests/project-upload-course-static.test.mjs`：

```js
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

assert.match(upload, /getCourses/, 'ProjectUploadView should load student course options.')
assert.match(upload, /form\.courseId/, 'ProjectUploadView should keep selected course id in form state.')
assert.match(upload, /请选择关联课程/, 'ProjectUploadView should validate course selection before submit.')
assert.match(upload, /course_id:\s*selectedCourseId/, 'Project payload should include course_id.')
assert.match(upload, /关联课程/, 'ProjectUploadView should render a course selection field.')
assert.match(projectApi, /course_id:\s*number/, 'ProjectPayload should require course_id.')
```

- [ ] **Step 7: 运行前端验证**

Run:

```powershell
node frontend\tests\project-upload-course-static.test.mjs
npm run build
```

Working directory for `npm run build`: `frontend`

Expected: 静态测试无输出且 exit code 为 0；前端构建通过。

---

### Task 5: 清理 StudentProgress 陈旧引用和文档事实

**Files:**
- Modify: `backend/tests/test_integration_bugfixes.py`
- Modify: `docs/superpowers/project-map.md`

- [ ] **Step 1: 删除陈旧测试导入**

在 `backend/tests/test_integration_bugfixes.py` 顶部 import 中移除 `StudentProgress`：

```python
from app.models.entities import Announcement, AnnouncementClass, Class, Course, Material, Project, Question, StoredFile, StudentClassEnrollment, TaskCompletion, User
```

- [ ] **Step 2: 删除已失效测试**

删除 `test_quiz_progress_is_course_based` 整个测试方法：

```python
    def test_quiz_progress_is_course_based(self, client, db_session, student_token):
        client.post("/api/quiz/submit", json={"question_id": 1, "user_answer": "B"}, headers=auth_header(student_token))
        progress = db_session.query(StudentProgress).filter(StudentProgress.user_id == "2025001").first()

        assert progress is not None
        assert progress.course_id == 1
        assert progress.questions_done == 1
```

原因：`StudentProgress` 已从当前模型中完全删除，答题统计以 `QuizAttempt` 为事实来源。

- [ ] **Step 3: 给现有作品创建测试补充 course_id**

在 `backend/tests/test_integration_bugfixes.py` 中，所有 `client.post("/api/projects", json={...})` 的测试 payload 都补充当前学生已加入的课程：

```python
"course_id": 1,
```

具体需要检查这些附近的作品创建调用：

```text
backend/tests/test_integration_bugfixes.py:633
backend/tests/test_integration_bugfixes.py:697
backend/tests/test_integration_bugfixes.py:755
backend/tests/test_integration_bugfixes.py:783
```

修改后的 payload 形态应类似：

```python
resp = client.post(
    "/api/projects",
    json={
        "course_id": 1,
        "title": "测试作品",
        "description": "作品说明",
        "tags": ["AI"],
    },
    headers=auth_header(student_token),
)
```

同时检查驳回后重新提交的 `client.put(f"/api/projects/{pid}", json={...})` payload，也要补充：

```python
"course_id": 1,
```

该调用当前位于：

```text
backend/tests/test_integration_bugfixes.py:797
```

- [ ] **Step 4: 更新项目地图**

在 `docs/superpowers/project-map.md` 的核心业务结构中：

```text
User(teacher) -> Course -> Project
```

替换掉：

```text
User(teacher) -> Course -> StudentProgress
```

在长期约定中把：

```text
- 资料、题目、学习进度全部直接挂在课程下。
```

改为：

```text
- 资料、题目和作品直接挂在课程下；答题统计以 QuizAttempt 为事实来源。
```

并增加规则：

```text
- 学生提交作品必须选择自己已加入班级对应的课程；教师只能审核自己课程范围内的作品。
```

- [ ] **Step 5: 运行陈旧引用检查**

Run:

```powershell
rg -n "StudentProgress|student_progress" backend\app backend\tests docs\superpowers\project-map.md
```

Expected:

- `backend/app/db/schema_compat.py` 中可能仍保留 `student_progress` 旧库兼容列处理。
- `backend/tests/test_integration_bugfixes.py` 和 `docs/superpowers/project-map.md` 不再出现 `StudentProgress`。

---

### Task 6: 总体验证和图谱同步

**Files:**
- No direct source changes unless previous tasks reveal failures.

- [ ] **Step 1: 后端目标测试**

Run:

```powershell
py -m pytest backend\tests\test_project_course_scope.py backend\tests\test_assignment_practice_flow.py backend\tests\test_schema_compat.py backend\tests\test_integration_bugfixes.py -q
```

Expected: 全部通过。若 `test_integration_bugfixes.py` 暴露与本任务无关的历史失败，先记录具体失败，不扩大修改范围。

- [ ] **Step 2: 前端目标测试和构建**

Run:

```powershell
node frontend\tests\message-refresh-static.test.mjs
node frontend\tests\project-upload-course-static.test.mjs
npm run build
```

Working directory for `npm run build`: `frontend`

Expected: 静态测试通过，构建通过。

- [ ] **Step 3: 代码格式和工作区检查**

Run:

```powershell
git diff --check
git status --porcelain=v1 -uall
```

Expected: `git diff --check` 无输出；`git status` 只显示本任务相关文件。

- [ ] **Step 4: 同步 graphify 图谱**

Run:

```powershell
graphify update .
```

如果当前环境没有 `graphify` 命令，则运行：

```powershell
& (Get-Content graphify-out\.graphify_python) -m graphify update .
```

Expected: 图谱更新完成。若 graphify 工具本身失败，在总结中说明，不阻塞业务代码验收。

- [ ] **Step 5: 最终验收口径**

验收时至少确认：

- 学生提交作品页面显示“关联课程”必填下拉框。
- 未选择课程时前端提示“请选择关联课程”。
- 学生选择未加入课程提交时后端返回 `code=403`。
- T2 教师不能审核、驳回或删除 T1 课程作品。
- T1 教师能正常审核自己课程作品。
- 教师作品审核列表只出现自己课程范围内作品。
- 已删除的 `StudentProgress` 不再导致测试收集失败。
