package com.awsstudy.demo.note;

import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

@RestController
@RequestMapping("/api/notes")
@RequiredArgsConstructor   // 위 NoteService의 손으로 쓴 생성자와 똑같은 일을 자동으로 해줌
public class NoteController {

    private final NoteService noteService;   // Repository가 아니라 Service에 의존

    @GetMapping
    public List<NoteResponse> list() {
        return noteService.findAll();
    }

    @PostMapping
    public NoteResponse create(@RequestBody CreateNoteRequest request) {
        return noteService.create(request);
    }
}
