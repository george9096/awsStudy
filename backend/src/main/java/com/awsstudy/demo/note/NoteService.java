package com.awsstudy.demo.note;

import org.springframework.data.domain.Sort;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

/**
 * 노트 비즈니스 로직 + 트랜잭션 경계.
 * 컨트롤러는 이 Service만 호출하고, Repository는 여기서만 쓴다.
 */
@Service
public class NoteService {

    private final NoteRepository repository;

    // 생성자 주입 — @RequiredArgsConstructor가 자동 생성해주던 코드가 바로 이것이다.
    public NoteService(NoteRepository repository) {
        this.repository = repository;
    }

    @Transactional(readOnly = true)
    public List<NoteResponse> findAll() {
        return repository.findAll(Sort.by(Sort.Direction.DESC, "id"))
                .stream()
                .map(NoteResponse::from)
                .toList();
    }

    @Transactional
    public NoteResponse create(CreateNoteRequest request) {
        Note note = new Note();
        note.setContent(request.content());
        Note saved = repository.save(note);
        return NoteResponse.from(saved);
    }
}
