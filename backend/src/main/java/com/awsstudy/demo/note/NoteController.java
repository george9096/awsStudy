package com.awsstudy.demo.note;

import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Sort;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/api/notes")
@RequiredArgsConstructor
public class NoteController {

    private final NoteRepository repository;

    @GetMapping
    public List<Note> list() {
        return repository.findAll(Sort.by(Sort.Direction.DESC, "id"));
    }

    @PostMapping
    public Note create(@RequestBody Map<String, String> body) {
        Note note = new Note();
        note.setContent(body.getOrDefault("content", ""));
        return repository.save(note);
    }
}
